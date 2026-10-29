import Foundation
import Testing
@testable import YT4SCore

/// The Looks-outdated banner and early stop (#11, #31), on the real Queue against the fake
/// yt-dlp's `outdated` scenario.
@MainActor @Suite struct OutdatedBannerTests {
    private func request(_ fake: FakeYtDlp, id: String) -> DownloadRequest {
        DownloadRequest(url: "https://www.youtube.com/watch?v=\(id)", downloadFolder: fake.downloadFolder, options: .default)
    }

    /// A Queue whose videos fail as Looks outdated when their ID is in `failing` (every video when nil).
    private func queue(_ fake: FakeYtDlp, failing: [String]? = nil) -> Queue {
        let extra = failing.map { ["YT4S_FAKE_FAIL_IDS": $0.joined(separator: ",")] } ?? [:]
        return Queue(runner: fake.runner(scenario: "outdated", extraEnvironment: extra))
    }

    private func run(_ queue: Queue, _ fake: FakeYtDlp, _ ids: [String]) async {
        for id in ids { queue.add(request(fake, id: id)) }
        await queue.waitUntilIdle()
    }

    @Test func twoLooksOutdatedFailuresInABatchShowTheBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake, failing: ["a", "c"])

        await run(queue, fake, ["a", "b", "c"])

        #expect(queue.items.map(\.isFailed) == [true, false, true])
        #expect(queue.showsOutdatedBanner)
    }

    @Test func oneLooksOutdatedFailureAmongSeveralVideosShowsNoBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake, failing: ["b"])

        await run(queue, fake, ["a", "b", "c"])

        #expect(!queue.showsOutdatedBanner)
    }

    @Test func aSingleVideoBatchThatLooksOutdatedShowsTheBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake)

        await run(queue, fake, ["a"])

        #expect(queue.showsOutdatedBanner)
    }

    @Test func otherFailuresNeverShowTheBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "video-failure"))

        await run(queue, fake, ["a", "b"])

        #expect(queue.items.map(\.isFailed) == [true, true])
        #expect(!queue.showsOutdatedBanner)
    }

    @Test func failuresInAnEarlierBatchDoNotCountTowardsTheNextOne() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake, failing: ["a", "c"])

        await run(queue, fake, ["a", "b"])
        await run(queue, fake, ["c", "d"])

        #expect(!queue.showsOutdatedBanner)
    }

    @Test func theBannerSaysWhatToDo() {
        #expect(OutdatedBanner.text(updateAppliedThisSession: false) == "YouTube may have changed. Try Update yt-dlp below.")
    }

    // MARK: - Early stop

    /// A Queue whose outcome is read from a file before each run, so a test can fix YouTube midway.
    private func switchableQueue(_ fake: FakeYtDlp, scenario: String, log: Bool = false) throws -> (Queue, URL, URL) {
        let root = fake.downloadFolder.deletingLastPathComponent()
        let scenarioFile = root.appendingPathComponent("scenario")
        let runLog = root.appendingPathComponent("runs.log")
        try scenario.write(to: scenarioFile, atomically: true, encoding: .utf8)
        let queue = Queue(runner: fake.runner(
            scenario: "success",
            extraEnvironment: ["YT4S_FAKE_SCENARIO_FILE": scenarioFile.path, "YT4S_FAKE_RUN_LOG": runLog.path]
        ))
        return (queue, scenarioFile, runLog)
    }

    private func runs(_ log: URL) -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    @Test func threeLooksOutdatedFailuresInARowStopTheRestOfTheBatch() async throws {
        let fake = try FakeYtDlp()
        let (queue, _, runLog) = try switchableQueue(fake, scenario: "outdated")

        await run(queue, fake, ["a", "b", "c", "d", "e"])

        #expect(queue.items.map(\.isFailed) == [true, true, true, false, false])
        #expect(queue.items[3].state == .notStarted)
        #expect(queue.items[4].state == .notStarted)
        #expect(runs(runLog) == 3)
        #expect(queue.showsOutdatedBanner)
        #expect(QueueSummary(queue.items).text == "3 failed, 2 not started")
        #expect(QueueRow(queue.items[3]).status == "Not started")
        #expect(QueueRow(queue.items[3]).actions == [.retry, .remove])
    }

    @Test func aVideoThatWorksBetweenFailuresKeepsTheBatchGoing() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake, failing: ["a", "b", "d", "e"])

        await run(queue, fake, ["a", "b", "c", "d", "e"])

        #expect(queue.items.map(\.isFailed) == [true, true, false, true, true])
    }

    @Test func otherFailuresNeverStopTheBatch() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "video-failure"))

        await run(queue, fake, ["a", "b", "c", "d"])

        #expect(queue.items.map(\.isFailed) == [true, true, true, true])
    }

    @Test func retryAllFailedResumesTheVideosThatWereNotStarted() async throws {
        let fake = try FakeYtDlp()
        let (queue, scenarioFile, _) = try switchableQueue(fake, scenario: "outdated")
        await run(queue, fake, ["a", "b", "c", "d"])
        #expect(QueueSummary(queue.items).retryableFailures == 4)

        try "success".write(to: scenarioFile, atomically: true, encoding: .utf8)
        queue.retryAllFailed()
        await queue.waitUntilIdle()

        #expect(queue.items.map(\.isFinished) == [true, true, true, true])
    }

    @Test func retryResumesOneVideoThatWasNotStarted() async throws {
        let fake = try FakeYtDlp()
        let (queue, scenarioFile, _) = try switchableQueue(fake, scenario: "outdated")
        await run(queue, fake, ["a", "b", "c", "d"])

        try "success".write(to: scenarioFile, atomically: true, encoding: .utf8)
        queue.retry(queue.items[3].id)
        await queue.waitUntilIdle()

        #expect(queue.items[3].isFinished)
    }

    // MARK: - Dismissing

    @Test func theCloseButtonDismissesTheBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake)
        await run(queue, fake, ["a"])

        queue.dismissOutdatedBanner()

        #expect(!queue.showsOutdatedBanner)
    }

    @Test func clearFinishedDismissesTheBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake)
        await run(queue, fake, ["a"])

        queue.clearFinished()

        #expect(!queue.showsOutdatedBanner)
    }

    @Test func aDismissedBannerNeedsNewFailuresToShowAgain() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake, failing: ["a", "b", "d", "e"])
        queue.add(request(fake, id: "a"))
        queue.add(request(fake, id: "b"))
        queue.add(request(fake, id: "c"))
        queue.add(request(fake, id: "d"))
        queue.add(request(fake, id: "e"))
        await queue.waitUntilIdle()
        queue.dismissOutdatedBanner()
        #expect(!queue.showsOutdatedBanner)

        await run(queue, fake, ["f"])
        #expect(queue.items[5].isFinished)
        #expect(!queue.showsOutdatedBanner)
    }

    // MARK: - With Update yt-dlp

    /// An update model over a sandboxed install whose bundled yt-dlp is 2026.10.20.
    private func updates() throws -> (YtDlpUpdateModel, FakeNightlyFeed) {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-banner-\(UUID().uuidString)", isDirectory: true)
        let executable = sandbox.appendingPathComponent("YT4S.app/Contents/Resources/bin/yt-dlp/yt-dlp_macos")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 2026.10.20\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let installations = YtDlpInstallations(
            root: sandbox.appendingPathComponent("yt-dlp", isDirectory: true),
            bundled: BundledYtDlp(executable: executable, version: YtDlpVersion("2026.10.20"))
        )
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")
        return (YtDlpUpdateModel(updater: YtDlpUpdater(installations: installations, http: feed), downloadsRunning: { false }), feed)
    }

    @Test func aSuccessfulUpdateDismissesTheBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake)
        let (ytDlp, _) = try updates()
        queue.dismissesOutdatedBanner(whenSwitching: ytDlp)
        await run(queue, fake, ["a"])
        #expect(!ytDlp.hasAppliedUpdateThisSession)

        await ytDlp.update()

        #expect(ytDlp.hasAppliedUpdateThisSession)
        #expect(!queue.showsOutdatedBanner)
    }

    @Test func aFailedUpdateKeepsTheBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake)
        let (ytDlp, feed) = try updates()
        queue.dismissesOutdatedBanner(whenSwitching: ytDlp)
        await run(queue, fake, ["a"])

        feed.failure = URLError(.notConnectedToInternet)
        await ytDlp.update()

        #expect(!ytDlp.hasAppliedUpdateThisSession)
        #expect(queue.showsOutdatedBanner)
    }

    @Test func failuresAfterAnUpdateAlsoSuggestRollBack() {
        #expect(OutdatedBanner.text(updateAppliedThisSession: true)
            == "YouTube may have changed. Try Update yt-dlp below, or Roll back if the last update made things worse.")
    }
}
