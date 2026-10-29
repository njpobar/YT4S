import Foundation
import Testing
@testable import YT4SCore

/// The real Queue and runner, end to end against the fake yt-dlp.
///
/// Mid-download checks hold the fake at a progress step (`FakeYtDlp.hold(at:)`) and wait on
/// conditions, never on wall-clock budgets: under load the fake can take seconds to start.
/// The time limit only catches a hang.
@MainActor @Suite(.timeLimit(.minutes(1))) struct QueueTests {
    private func request(_ fake: FakeYtDlp, id: String = "abc123") -> DownloadRequest {
        DownloadRequest(url: "https://www.youtube.com/watch?v=\(id)", downloadFolder: fake.downloadFolder, options: .default)
    }

    private func fraction(_ item: QueueItem) -> Double? {
        if case .running(let progress) = item.state { progress.fraction } else { nil }
    }

    /// A quit mid-download leaves yt-dlp's unfinished output behind; the next launch removes it
    /// before anything downloads. Finished files next to it are never touched.
    @Test func leftoversOfAnEarlierSessionAreRemoved() throws {
        let fake = try FakeYtDlp()
        let partials = fake.downloadFolder.deletingLastPathComponent().appendingPathComponent("partial")
        let queue = Queue(runner: fake.runner(scenario: "success"), partialFilesFolder: partials)
        let incomplete = DownloadFolder(url: fake.downloadFolder).incompleteFolder
        let saved = fake.downloadFolder.appendingPathComponent("Me at the zoo.mp4")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: incomplete.appendingPathComponent("jNQXAC9IVRw.mp4"))
        try FileManager.default.createDirectory(at: partials.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        try Data("done".utf8).write(to: saved)

        queue.removeLeftovers(in: fake.downloadFolder)

        #expect(!FileManager.default.fileExists(atPath: incomplete.path))
        #expect(!FileManager.default.fileExists(atPath: partials.path))
        #expect(FileManager.default.fileExists(atPath: saved.path))
    }

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
        let hold = fake.hold(at: 50)
        defer { try? hold.release() }
        let queue = Queue(runner: fake.runner(scenario: "success", extraEnvironment: hold.environment))

        queue.add(request(fake))
        try await waitUntil { fraction(queue.items[0]) == 0.5 }
        #expect(queue.items[0].title == "Fake Video abc123")

        try hold.release()
        await queue.waitUntilIdle()
        #expect(queue.items[0].isFinished)
    }

    @Test func videosDownloadOneAtATimeInOrder() async throws {
        let fake = try FakeYtDlp()
        let hold = fake.hold(at: 0)
        defer { try? hold.release() }
        let queue = Queue(runner: fake.runner(scenario: "success", extraEnvironment: hold.environment))

        queue.add(request(fake, id: "first"))
        queue.add(request(fake, id: "second"))
        try await waitUntil { fraction(queue.items[0]) == 0 }
        #expect(queue.items[1].state == .pending)

        try hold.release()
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

    // MARK: - Queue controls (#22)

    /// Every file under `folder`, recursively, as paths relative to it.
    private func files(in folder: URL) -> [String] {
        (FileManager.default.subpaths(atPath: folder.path) ?? []).filter { path in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }
    }

    @Test func cancellingARunningVideoStopsItAndLeavesNoPartialFiles() async throws {
        let fake = try FakeYtDlp()
        let partials = fake.downloadFolder.deletingLastPathComponent().appendingPathComponent("partial")
        let hold = fake.hold(at: 25)
        defer { try? hold.release() }
        let queue = Queue(runner: fake.runner(scenario: "success", extraEnvironment: hold.environment), partialFilesFolder: partials)

        let id = queue.add(request(fake))
        try await waitUntil { fraction(queue.items[0]) == 0.25 }
        #expect(!files(in: partials).isEmpty, "the partial file is written under the partial files folder")

        queue.cancel(id)
        await queue.waitUntilIdle()

        #expect(queue.items[0].state == .cancelled)
        #expect(files(in: partials).isEmpty)
        #expect(files(in: fake.downloadFolder).isEmpty)
    }

    @Test func cancellingAWaitingVideoSkipsItAndTheQueueCarriesOn() async throws {
        let fake = try FakeYtDlp()
        let hold = fake.hold(at: 0)
        defer { try? hold.release() }
        let queue = Queue(runner: fake.runner(scenario: "success", extraEnvironment: hold.environment))

        let first = queue.add(request(fake, id: "first"))
        let second = queue.add(request(fake, id: "second"))
        queue.add(request(fake, id: "third"))
        try await waitUntil { fraction(queue.items[0]) == 0 }

        queue.cancel(second)
        #expect(queue.items[1].state == .cancelled)
        queue.cancel(first)
        // Released only once the first run is stopped, so it cannot finish ahead of Cancel.
        try await waitUntil { queue.items[0].state == .cancelled }
        try hold.release()
        await queue.waitUntilIdle()

        #expect(queue.items.map { $0.state == .cancelled } == [true, true, false])
        #expect(queue.items[2].isFinished)
        #expect(files(in: fake.downloadFolder) == ["Fake Video third.mp4"])
    }

    @Test func retryRerunsAFailedVideoWithItsOriginalChoicesAfterDeletingPartialFiles() async throws {
        let fake = try FakeYtDlp()
        let partials = fake.downloadFolder.deletingLastPathComponent().appendingPathComponent("partial")
        let scenarioFile = fake.downloadFolder.deletingLastPathComponent().appendingPathComponent("scenario")
        try "network-drop".write(to: scenarioFile, atomically: true, encoding: .utf8)
        let queue = Queue(
            runner: fake.runner(scenario: "success", extraEnvironment: ["YT4S_FAKE_SCENARIO_FILE": scenarioFile.path]),
            partialFilesFolder: partials,
            networkRetryDelay: .zero
        )
        let original = DownloadRequest(
            url: "https://www.youtube.com/watch?v=abc123",
            downloadFolder: fake.downloadFolder,
            options: .default
        )

        let id = queue.add(original)
        await queue.waitUntilIdle()
        #expect(queue.items[0].isFailed)
        let firstArgv = try fake.loggedArgv()

        // A stray partial file from the failed attempt must not be resumed or left behind.
        let stray = queue.partialFilesFolder(for: id).appendingPathComponent("Fake Video abc123.mp4.part")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "stale".write(to: stray, atomically: true, encoding: .utf8)
        try "success".write(to: scenarioFile, atomically: true, encoding: .utf8)

        queue.retry(id)
        #expect(queue.items[0].state == .pending)
        await queue.waitUntilIdle()

        #expect(queue.items.count == 1)
        #expect(queue.items[0].isFinished)
        #expect(queue.items[0].request == original)
        #expect(try fake.loggedArgv() == firstArgv)
        #expect(files(in: partials).isEmpty)
        #expect(files(in: fake.downloadFolder) == ["Fake Video abc123.mp4"])
    }

    @Test func retryBringsBackACancelledVideo() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "slow", extraEnvironment: ["YT4S_FAKE_STEP_DELAY": "0.1"]))

        queue.add(request(fake, id: "first"))
        let second = queue.add(request(fake, id: "second"))
        queue.cancel(second)
        await queue.waitUntilIdle()
        #expect(queue.items[1].state == .cancelled)

        queue.retry(second)
        await queue.waitUntilIdle()

        #expect(queue.items[1].isFinished)
    }

    @Test func retryLeavesFinishedAndActiveVideosAlone() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "success"))

        let id = queue.add(request(fake))
        await queue.waitUntilIdle()
        let finished = queue.items[0].state

        queue.retry(id)

        #expect(queue.items[0].state == finished)
        #expect(queue.isIdle)
    }

    @Test func clearFinishedRemovesOnlyFinishedRows() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "video-failure", extraEnvironment: ["YT4S_FAKE_FAIL_IDS": "bad"]))

        queue.add(request(fake, id: "good"))
        queue.add(request(fake, id: "bad"))
        let cancelled = queue.add(request(fake, id: "later"))
        queue.cancel(cancelled)
        await queue.waitUntilIdle()

        queue.clearFinished()

        #expect(queue.items.map(\.request) == [request(fake, id: "bad"), request(fake, id: "later")])
        #expect(queue.items[0].isFailed)
        #expect(queue.items[1].state == .cancelled)
        #expect(files(in: fake.downloadFolder) == ["Fake Video good.mp4"], "clearing a row never deletes its file")
    }

    @Test func removeDropsACancelledRowButNotAnActiveOne() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "slow", extraEnvironment: ["YT4S_FAKE_STEP_DELAY": "0.1"]))

        let running = queue.add(request(fake, id: "first"))
        let cancelled = queue.add(request(fake, id: "second"))
        queue.cancel(cancelled)
        queue.remove(cancelled)
        queue.remove(running)

        #expect(queue.items.map(\.id) == [running])
        await queue.waitUntilIdle()
        #expect(queue.items[0].isFinished)
    }

    @Test func hasActiveDownloadsWhileAnyVideoIsWaitingOrRunning() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "slow", extraEnvironment: ["YT4S_FAKE_STEP_DELAY": "0.1"]))
        #expect(!queue.hasActiveDownloads)

        let first = queue.add(request(fake, id: "first"))
        let second = queue.add(request(fake, id: "second"))
        #expect(queue.hasActiveDownloads)

        queue.cancel(second)
        #expect(queue.hasActiveDownloads, "the first video is still going")
        queue.cancel(first)
        await queue.waitUntilIdle()

        #expect(!queue.hasActiveDownloads)
    }

    @Test func reportsOnceWhenABatchFinishes() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "video-failure", extraEnvironment: ["YT4S_FAKE_FAIL_IDS": "bad"]))
        var reports: [String] = []
        queue.onBatchFinished = { reports.append($0.text) }

        queue.add(request(fake, id: "good"))
        queue.add(request(fake, id: "bad"))
        await queue.waitUntilIdle()
        #expect(reports == ["1 downloaded, 1 failed"])

        queue.add(request(fake, id: "again"))
        await queue.waitUntilIdle()
        #expect(reports == ["1 downloaded, 1 failed", "2 downloaded, 1 failed"])
    }

    // MARK: - Failure categories (#26)

    private func failure(_ item: QueueItem) -> DownloadFailure? {
        if case .failed(let failure) = item.state { failure } else { nil }
    }

    /// A runner whose fake appends one line per yt-dlp run to the returned log.
    private func countingRunner(_ fake: FakeYtDlp, scenario: String, extra: [String: String] = [:]) -> (YtDlpRunner, URL) {
        let log = fake.downloadFolder.deletingLastPathComponent().appendingPathComponent("runs.log")
        return (fake.runner(scenario: scenario, extraEnvironment: extra.merging(["YT4S_FAKE_RUN_LOG": log.path]) { a, _ in a }), log)
    }

    private func runs(_ log: URL) -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    @Test func aFailedVideoIsCategorizedFromYtDlpOutput() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "outdated"))

        queue.add(request(fake))
        await queue.waitUntilIdle()

        #expect(failure(queue.items[0])?.category == .looksOutdated)
    }

    @Test func aNetworkDropIsRetriedOnceAutomatically() async throws {
        let fake = try FakeYtDlp()
        let (runner, log) = countingRunner(fake, scenario: "network-drop-once")
        let queue = Queue(runner: runner, networkRetryDelay: .zero)

        queue.add(request(fake))
        await queue.waitUntilIdle()

        #expect(queue.items[0].isFinished)
        #expect(runs(log) == 2)
        #expect(files(in: fake.downloadFolder) == ["Fake Video abc123.mp4"])
    }

    @Test func aNetworkDropThatPersistsFailsAfterOneAutomaticRetry() async throws {
        let fake = try FakeYtDlp()
        let (runner, log) = countingRunner(fake, scenario: "network-drop")
        let queue = Queue(runner: runner, networkRetryDelay: .zero)

        queue.add(request(fake))
        await queue.waitUntilIdle()

        #expect(failure(queue.items[0])?.category == .network)
        #expect(runs(log) == 2)
    }

    @Test func otherFailuresAreNotRetriedAutomatically() async throws {
        let fake = try FakeYtDlp()
        let (runner, log) = countingRunner(fake, scenario: "outdated")
        let queue = Queue(runner: runner, networkRetryDelay: .zero)

        queue.add(request(fake))
        await queue.waitUntilIdle()

        #expect(failure(queue.items[0])?.category == .looksOutdated)
        #expect(runs(log) == 1)
    }

    @Test func theAutomaticRetryWaitsAShortDelayAndCanBeCancelled() async throws {
        let fake = try FakeYtDlp()
        let (runner, log) = countingRunner(fake, scenario: "network-drop")
        let queue = Queue(runner: runner, networkRetryDelay: .seconds(30))

        let id = queue.add(request(fake))
        try await waitUntil { runs(log) == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(runs(log) == 1, "the second run waits for the delay")
        #expect(queue.items[0].isActive, "the row is not failed while waiting to retry")

        queue.cancel(id)
        await queue.waitUntilIdle()

        #expect(queue.items[0].state == .cancelled)
        #expect(runs(log) == 1)
    }

    @Test func retryDoesNothingForAVideoThatCannotSucceedAgain() async throws {
        let fake = try FakeYtDlp()
        let (runner, log) = countingRunner(fake, scenario: "video-failure")
        let queue = Queue(runner: runner)

        let id = queue.add(request(fake))
        await queue.waitUntilIdle()
        #expect(failure(queue.items[0])?.category == .unavailable)

        queue.retry(id)

        #expect(queue.items[0].isFailed)
        #expect(queue.isIdle)
        #expect(runs(log) == 1)
    }

    @Test func retryAllFailedRetriesEveryRetryableFailedRow() async throws {
        let fake = try FakeYtDlp()
        let scenarioFile = fake.downloadFolder.deletingLastPathComponent().appendingPathComponent("scenario")
        try "outdated".write(to: scenarioFile, atomically: true, encoding: .utf8)
        let queue = Queue(runner: fake.runner(scenario: "success", extraEnvironment: ["YT4S_FAKE_SCENARIO_FILE": scenarioFile.path]))

        queue.add(request(fake, id: "first"))
        queue.add(request(fake, id: "second"))
        await queue.waitUntilIdle()
        try "video-failure".write(to: scenarioFile, atomically: true, encoding: .utf8)
        queue.add(request(fake, id: "removed"))
        let cancelled = queue.add(request(fake, id: "cancelled"))
        queue.cancel(cancelled)
        await queue.waitUntilIdle()
        #expect(QueueSummary(queue.items).retryableFailures == 2)

        try "success".write(to: scenarioFile, atomically: true, encoding: .utf8)
        queue.retryAllFailed()
        await queue.waitUntilIdle()

        #expect(queue.items[0].isFinished)
        #expect(queue.items[1].isFinished)
        #expect(failure(queue.items[2])?.category == .unavailable)
        #expect(queue.items[3].state == .cancelled)
    }
}
