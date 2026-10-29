import Foundation
import Testing
@testable import YT4SCore

/// Drives the fake yt-dlp fixture through the same invocation path the app uses.
@Suite struct FakeYtDlpTests {
    @Test func successDownloadsFileAndPrintsFinalPath() async throws {
        let fake = try FakeYtDlp()
        let result = try await fake.run(
            [
                "--print", "after_move:%(id)s\t%(filepath)s",
                "-P", fake.downloadFolder.path,
                "-o", "%(title)s.%(ext)s",
                "https://www.youtube.com/watch?v=abc123",
            ],
            scenario: "success"
        )

        #expect(result.termination == .exited(0))
        let expectedPath = fake.downloadFolder.appendingPathComponent("Fake Video abc123.mp4").path
        #expect(result.stdoutLines.contains("abc123\t\(expectedPath)"))
        #expect(FileManager.default.fileExists(atPath: expectedPath))
    }

    @Test func everyInvocationCarriesTheMandatoryFlags() async throws {
        let fake = try FakeYtDlp()
        _ = try await fake.run(["--simulate", "https://youtu.be/abc123"], scenario: "success")

        let argv = try fake.loggedArgv()
        #expect(argv.starts(with: [
            "--ignore-config",
            "--no-update",
            "--ffmpeg-location", fake.tools.ffmpegDirectory.path,
            "--js-runtimes", "deno:\(fake.tools.deno.path)",
        ]))
        #expect(argv.last == "https://youtu.be/abc123")
    }

    @Test func fakeRejectsAnInvocationWithoutTheMandatoryFlags() async throws {
        let fake = try FakeYtDlp()
        let result = try await fake.runRaw(["https://youtu.be/abc123"], scenario: "success")

        #expect(result.termination == .exited(2))
        #expect(result.stderr.contains("missing required flag --ignore-config"))
    }

    @Test func progressTemplateEmitsOneLinePerStep() async throws {
        let fake = try FakeYtDlp()
        let result = try await fake.run(
            [
                "--quiet", "--progress", "--newline",
                "--progress-template", "download:%(info.id)s %(progress.downloaded_bytes)s/%(progress.total_bytes)s %(progress.status)s",
                "-P", fake.downloadFolder.path,
                "https://youtu.be/abc123",
            ],
            scenario: "success"
        )

        #expect(result.stdoutLines == [
            "abc123 0/10485760 downloading",
            "abc123 2621440/10485760 downloading",
            "abc123 5242880/10485760 downloading",
            "abc123 7864320/10485760 downloading",
            "abc123 10485760/10485760 finished",
        ])
    }

    @Test func perVideoFailureFailsOnlyTheNamedVideo() async throws {
        let fake = try FakeYtDlp()
        let result = try await fake.run(
            ["--print", "after_move:%(id)s", "-P", fake.downloadFolder.path, "https://youtu.be/good", "https://youtu.be/bad"],
            scenario: "video-failure",
            extraEnvironment: ["YT4S_FAKE_FAIL_IDS": "bad"]
        )

        #expect(result.termination == .exited(1))
        #expect(result.stdoutLines == ["good"])
        #expect(result.stderrLines == ["ERROR: [youtube] bad: Video unavailable. This video has been removed by the uploader"])
    }

    @Test func networkDropFailsMidDownloadAndLeavesAPartialFile() async throws {
        let fake = try FakeYtDlp()
        let result = try await fake.run(
            ["-P", fake.downloadFolder.path, "-o", "%(id)s.%(ext)s", "https://youtu.be/abc123"],
            scenario: "network-drop"
        )

        #expect(result.termination == .exited(1))
        #expect(result.stderr.contains("ERROR: [download] Got error:"))
        #expect(result.stderr.contains("Read timed out"))
        let folder = fake.downloadFolder.path
        #expect(FileManager.default.fileExists(atPath: folder + "/abc123.mp4.part"))
        #expect(!FileManager.default.fileExists(atPath: folder + "/abc123.mp4"))
    }

    @Test func outdatedScenarioLooksLikeABrokenExtractor() async throws {
        let fake = try FakeYtDlp()
        let result = try await fake.run(["https://youtu.be/abc123"], scenario: "outdated")

        #expect(result.termination == .exited(1))
        #expect(result.stderr.contains("ERROR: [youtube] abc123: Unable to extract player response"))
        #expect(result.stderr.contains("nsig extraction failed"))
    }

    @Test func crashKillsTheProcessWithASignal() async throws {
        let fake = try FakeYtDlp()
        let result = try await fake.run(["-P", fake.downloadFolder.path, "https://youtu.be/abc123"], scenario: "crash")

        #expect(result.termination == .signaled(SIGSEGV))
        #expect(result.stderr.contains("Traceback (most recent call last):"))
    }

    /// The time limit only catches a hang: the run is held at 0% and never released.
    @Test(.timeLimit(.minutes(1)))
    func cancellingAHeldDownloadTerminatesTheProcess() async throws {
        let fake = try FakeYtDlp()
        let hold = fake.hold(at: 0)
        let environment = hold.environment.merging(["YT4S_FAKE_PID_FILE": fake.pidFile.path]) { $1 }
        let task = Task {
            try await fake.run(["-P", fake.downloadFolder.path, "https://youtu.be/abc123"], scenario: "success", extraEnvironment: environment)
        }
        try await waitUntil { fake.pid() != nil }
        task.cancel()
        let result = try await task.value

        #expect(result.termination == .signaled(SIGTERM))
    }

    @Test func versionPrintsTheConfiguredTag() async throws {
        let fake = try FakeYtDlp()
        let result = try await fake.runRaw(["--version"], scenario: "success", extraEnvironment: ["YT4S_FAKE_VERSION": "2026.10.26.220202"])

        #expect(result.termination == .exited(0))
        #expect(result.stdoutLines == ["2026.10.26.220202"])
    }

    @Test func partialFilesGoUnderTheTempPathAndAreRemovedOnSuccess() async throws {
        let fake = try FakeYtDlp()
        let temp = fake.downloadFolder.deletingLastPathComponent().appendingPathComponent("partial")
        let arguments = ["-P", "home:" + fake.downloadFolder.path, "-P", "temp:" + temp.path, "-o", "%(id)s.%(ext)s", "https://youtu.be/abc123"]

        let dropped = try await fake.run(arguments, scenario: "network-drop")
        #expect(dropped.termination == .exited(1))
        #expect(FileManager.default.fileExists(atPath: temp.path + "/abc123.mp4.part"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fake.downloadFolder.path).isEmpty)

        let succeeded = try await fake.run(arguments, scenario: "success")
        #expect(succeeded.termination == .exited(0))
        #expect(!FileManager.default.fileExists(atPath: temp.path + "/abc123.mp4.part"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fake.downloadFolder.path) == ["abc123.mp4"])
    }

    @Test func aScenarioFileOverridesTheScenarioBetweenRuns() async throws {
        let fake = try FakeYtDlp()
        let file = fake.downloadFolder.deletingLastPathComponent().appendingPathComponent("scenario")
        let arguments = ["-P", fake.downloadFolder.path, "https://youtu.be/abc123"]
        let environment = ["YT4S_FAKE_SCENARIO_FILE": file.path]

        try "outdated".write(to: file, atomically: true, encoding: .utf8)
        let first = try await fake.run(arguments, scenario: "success", extraEnvironment: environment)
        try "success".write(to: file, atomically: true, encoding: .utf8)
        let second = try await fake.run(arguments, scenario: "outdated", extraEnvironment: environment)

        #expect(first.termination == .exited(1))
        #expect(second.termination == .exited(0))
    }
}
