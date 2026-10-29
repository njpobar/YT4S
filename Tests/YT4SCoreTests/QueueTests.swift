import Foundation
import Testing
@testable import YT4SCore

/// The real Queue and runner, end to end against the fake yt-dlp.
@MainActor @Suite struct QueueTests {
    private func request(_ fake: FakeYtDlp, id: String = "abc123") -> DownloadRequest {
        DownloadRequest(url: "https://www.youtube.com/watch?v=\(id)", downloadFolder: fake.downloadFolder, options: .default)
    }

    /// Polls until `condition` holds, failing after `timeout`.
    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimeoutError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct TimeoutError: Error {}

    @Test func anAddedVideoIsPendingUntilItStarts() throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "success"))

        queue.add(request(fake))

        #expect(queue.items.count == 1)
        #expect(queue.items[0].state == .pending)
        #expect(queue.items[0].title == nil)
        #expect(queue.items[0].request == request(fake))
    }

    @Test func aSuccessfulDownloadFinishesWithItsTitleAndFile() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "success"))

        queue.add(request(fake))
        await queue.waitUntilIdle()

        let file = fake.downloadFolder.appendingPathComponent("Fake Video abc123.mp4")
        #expect(queue.items[0].title == "Fake Video abc123")
        #expect(queue.items[0].state == .finished(file: file))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: QualityPreset.allCases)
    func everyVideoPresetDownloadsAnMP4(quality: QualityPreset) async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "success"))
        var request = request(fake)
        request.options.quality = quality

        queue.add(request)
        await queue.waitUntilIdle()

        #expect(queue.items[0].state == .finished(file: fake.downloadFolder.appendingPathComponent("Fake Video abc123.mp4")))
        #expect(queue.items[0].request.options.quality == quality)
    }

    @Test func anMP3ItemFinishesWithAnMP3File() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "success"))
        var request = request(fake)
        request.options.format = .mp3

        queue.add(request)
        await queue.waitUntilIdle()

        let file = fake.downloadFolder.appendingPathComponent("Fake Video abc123.mp3")
        #expect(queue.items[0].state == .finished(file: file))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(queue.items[0].request.options.format == .mp3)
    }

    @Test func aRunningDownloadShowsLiveProgress() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "slow", extraEnvironment: ["YT4S_FAKE_STEP_DELAY": "0.2"]))

        queue.add(request(fake))
        try await eventually {
            if case .running(let progress) = queue.items[0].state { (progress.fraction ?? 0) >= 0.5 } else { false }
        }
        #expect(queue.items[0].title == "Fake Video abc123")

        await queue.waitUntilIdle()
        #expect(queue.items[0].isFinished)
    }

    @Test func videosDownloadOneAtATimeInOrder() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "slow", extraEnvironment: ["YT4S_FAKE_STEP_DELAY": "0.1"]))

        queue.add(request(fake, id: "first"))
        queue.add(request(fake, id: "second"))
        try await eventually { if case .running = queue.items[0].state { true } else { false } }
        #expect(queue.items[1].state == .pending)

        await queue.waitUntilIdle()
        #expect(queue.items.allSatisfy { $0.isFinished })
        #expect(queue.items.map(\.title) == ["Fake Video first", "Fake Video second"])
    }

    @Test func aCrashFailsTheItemAndKeepsTheRawOutputForDetails() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "crash"))

        queue.add(request(fake))
        await queue.waitUntilIdle()

        guard case .failed(let failure) = queue.items[0].state else {
            Issue.record("expected failed, got \(queue.items[0].state)")
            return
        }
        #expect(failure.termination == .signaled(SIGSEGV))
        #expect(failure.details.contains("Traceback (most recent call last):"))
    }

    @Test func aFailureDoesNotStopTheNextVideo() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "video-failure", extraEnvironment: ["YT4S_FAKE_FAIL_IDS": "bad"]))

        queue.add(request(fake, id: "bad"))
        queue.add(request(fake, id: "good"))
        await queue.waitUntilIdle()

        #expect(queue.items[0].isFailed)
        #expect(queue.items[1].isFinished)
    }

    @Test func anItemAddedAfterTheQueueWentIdleStillRuns() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "success"))

        queue.add(request(fake, id: "one"))
        await queue.waitUntilIdle()
        queue.add(request(fake, id: "two"))
        await queue.waitUntilIdle()

        #expect(queue.items.allSatisfy { $0.isFinished })
    }

    @Test func aYtDlpThatCannotLaunchFailsTheItem() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: YtDlpRunner(tools: BundledTools(
            ytDlp: URL(fileURLWithPath: "/nonexistent/yt-dlp_macos"),
            ffmpegDirectory: URL(fileURLWithPath: "/nonexistent"),
            deno: URL(fileURLWithPath: "/nonexistent/deno")
        )))

        queue.add(request(fake))
        await queue.waitUntilIdle()

        guard case .failed(let failure) = queue.items[0].state else {
            Issue.record("expected failed, got \(queue.items[0].state)")
            return
        }
        #expect(failure.termination == nil)
    }
}
