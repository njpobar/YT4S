import Foundation
import Testing
@testable import YT4SCore

/// The runner streams YT4S's machine-readable lines while yt-dlp runs, then reports how it ended.
@Suite struct YtDlpRunnerTests {
    private func collect(_ runner: YtDlpRunner, _ arguments: [String]) async throws -> (events: [YtDlpEvent], exit: YtDlpExit?) {
        var events: [YtDlpEvent] = []
        var exit: YtDlpExit?
        for try await update in runner.run(arguments) {
            switch update {
            case .event(let event): events.append(event)
            case .exited(let ended): exit = ended
            }
        }
        return (events, exit)
    }

    private func request(_ fake: FakeYtDlp, _ url: String = "https://www.youtube.com/watch?v=abc123") -> DownloadRequest {
        DownloadRequest(url: url, downloadFolder: fake.downloadFolder, options: .default)
    }

    @Test func streamsVideoProgressAndFileEventsInOrder() async throws {
        let fake = try FakeYtDlp()
        let (events, exit) = try await collect(fake.runner(scenario: "success"), DownloadArguments.arguments(for: request(fake)))

        let path = fake.downloadFolder.appendingPathComponent("Fake Video abc123.mp4").path
        #expect(events.first == .video(VideoInfo(id: "abc123", title: "Fake Video abc123", formatIDs: ["18"], partSizes: [10485760])))
        #expect(events.count == 7)
        #expect(events.last == .file(videoID: "abc123", path: path))
        #expect(exit == YtDlpExit(termination: .exited(0), stderr: ""))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func alwaysInvokesYtDlpWithTheMandatoryFlags() async throws {
        let fake = try FakeYtDlp()
        _ = try await collect(fake.runner(scenario: "success"), DownloadArguments.arguments(for: request(fake)))

        #expect(try fake.loggedArgv().starts(with: [
            "--ignore-config",
            "--no-update",
            "--ffmpeg-location", fake.tools.ffmpegDirectory.path,
            "--js-runtimes", "deno:\(fake.tools.deno.path)",
        ]))
    }

    @Test func eventsArriveWhileYtDlpIsStillRunning() async throws {
        let fake = try FakeYtDlp()
        let runner = fake.runner(scenario: "slow", extraEnvironment: ["YT4S_FAKE_STEP_DELAY": "0.3"])
        let started = ContinuousClock.now
        var firstProgressAt: Duration?
        for try await update in runner.run(DownloadArguments.arguments(for: request(fake))) {
            if case .event(.progress) = update, firstProgressAt == nil { firstProgressAt = ContinuousClock.now - started }
        }
        let total = ContinuousClock.now - started

        #expect(try #require(firstProgressAt) < total - .milliseconds(600))
    }

    @Test func aCrashEndsWithTheSignalAndTheRawStderr() async throws {
        let fake = try FakeYtDlp()
        let (events, exit) = try await collect(fake.runner(scenario: "crash"), DownloadArguments.arguments(for: request(fake)))

        #expect(!events.contains { if case .file = $0 { true } else { false } })
        let ended = try #require(exit)
        #expect(ended.termination == .signaled(SIGSEGV))
        #expect(ended.stderr.contains("Traceback (most recent call last):"))
    }

    @Test func cancellingTheConsumerTerminatesYtDlp() async throws {
        let fake = try FakeYtDlp()
        let runner = fake.runner(scenario: "slow")
        let started = ContinuousClock.now
        let task = Task {
            for try await _ in runner.run(DownloadArguments.arguments(for: request(fake))) {}
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result

        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aMissingExecutableThrows() async throws {
        let runner = YtDlpRunner(tools: BundledTools(
            ytDlp: URL(fileURLWithPath: "/nonexistent/yt-dlp_macos"),
            ffmpegDirectory: URL(fileURLWithPath: "/nonexistent"),
            deno: URL(fileURLWithPath: "/nonexistent/deno")
        ))

        await #expect(throws: (any Error).self) {
            for try await _ in runner.run(["--version"]) {}
        }
    }

    @Test func runsWhicheverYtDlpTheUpdaterSelectedAtTheTimeOfEachRun() async throws {
        let fake = try FakeYtDlp()
        let missing = YtDlpCopy(version: nil, executable: URL(fileURLWithPath: "/nonexistent/yt-dlp_macos"), origin: .bundled)
        let selection = YtDlpSelection(missing)
        let runner = YtDlpRunner(tools: fake.tools, environment: fake.environment(scenario: "success"), selection: selection)
        let arguments = DownloadArguments.arguments(for: request(fake))

        await #expect(throws: (any Error).self) { _ = try await collect(runner, arguments) }

        // An update installed a new copy while the app is open: the next run uses it.
        selection.select(YtDlpCopy(version: YtDlpVersion("2026.10.26.220202"), executable: fake.executable, origin: .downloaded))
        let (_, exit) = try await collect(runner, arguments)
        #expect(exit?.succeeded == true)
    }
}
