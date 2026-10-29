import Foundation
import Testing
@testable import YT4SCore

@Suite struct SubprocessTests {
    /// Cancel can arrive before the child is launched (e.g. Cancel pressed right as a video
    /// starts). The child must still never get to do its work.
    @Test func cancellingBeforeLaunchNeverLetsTheChildRun() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("yt4s-subprocess-\(UUID().uuidString)")
        let task = Task {
            try await Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 0.3; touch \"$0\"", marker.path]
            )
        }
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(600))

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// yt-dlp starts helpers (ffmpeg) that inherit its output. Cancel must stop them too: killing
    /// only yt-dlp would leave them running and `run` waiting on the still-open pipe until they
    /// finish. The time limit only catches that hang.
    @Test(.timeLimit(.minutes(1)))
    func cancellingAlsoStopsWhatTheChildStarted() async throws {
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            // `; :` keeps sh from exec-ing sleep, so sleep is sh's own child.
            try await Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo started; sleep 120; :"],
                onStdoutLine: { _ in startedContinuation.yield() }
            )
        }
        for await _ in started { break }

        task.cancel()
        let result = try await task.value

        #expect(result.termination == .signaled(SIGTERM))
    }

    /// Quitting YT4S mid-download: every child still running (yt-dlp with its ffmpeg, a listing,
    /// a preview) is stopped along with what it started, before the app exits.
    @Test(.timeLimit(.minutes(1)))
    func terminatingAllStopsEveryRunningChildAndItsHelpers() async throws {
        let children = ChildProcesses()
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let runs = (0..<2).map { _ in
            Task {
                try await Subprocess.run(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "echo started; sleep 120; :"],
                    children: children,
                    onStdoutLine: { _ in startedContinuation.yield() }
                )
            }
        }
        var count = 0
        for await _ in started { count += 1; if count == 2 { break } }

        let clock = ContinuousClock()
        let elapsed = clock.measure { children.terminateAll(gracePeriod: .seconds(20)) }

        #expect(elapsed < .seconds(10))
        for run in runs {
            #expect(try await run.value.termination == .signaled(SIGTERM))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func terminatingAllKillsAChildThatIgnoresSIGTERMAfterTheGracePeriod() async throws {
        let children = ChildProcesses()
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let run = Task {
            try await Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo started; sleep 120; :"],
                children: children,
                onStdoutLine: { _ in startedContinuation.yield() }
            )
        }
        for await _ in started { break }

        children.terminateAll(gracePeriod: .milliseconds(300))

        #expect(try await run.value.termination == .signaled(SIGKILL))
    }
}
