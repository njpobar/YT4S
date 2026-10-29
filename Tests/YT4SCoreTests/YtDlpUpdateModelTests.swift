import Foundation
import Testing
@testable import YT4SCore

/// What the footer's Update yt-dlp row shows and does.
@MainActor @Suite struct YtDlpUpdateModelTests {
    let installations: YtDlpInstallations
    let bundled: YtDlpCopy

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-update-model-\(UUID().uuidString)/yt-dlp", isDirectory: true)
        let executable = URL(fileURLWithPath: "/Applications/YT4S.app/Contents/Resources/bin/yt-dlp/yt-dlp_macos")
        installations = YtDlpInstallations(root: root, bundled: BundledYtDlp(executable: executable, version: YtDlpVersion("2026.10.20")))
        bundled = YtDlpCopy(version: YtDlpVersion("2026.10.20"), executable: executable, origin: .bundled)
    }

    private final class Downloads {
        var running = false
    }

    private func model(
        _ feed: HTTPClient,
        downloads: Downloads = Downloads(),
        checkInterval: Duration = .seconds(86_400)
    ) -> YtDlpUpdateModel {
        YtDlpUpdateModel(
            updater: YtDlpUpdater(installations: installations, http: feed),
            checkInterval: checkInterval,
            downloadsRunning: { downloads.running }
        )
    }

    @Test func beforeLaunchItRunsTheBundledCopyAndShowsNoBadge() throws {
        let model = model(try FakeNightlyFeed(tag: "2026.10.26.220202"))

        #expect(model.selection.copy == bundled)
        #expect(model.versionLabel == "yt-dlp 2026.10.20")
        #expect(!model.showsBadge)
        #expect(model.message == nil)
    }

    @Test func launchSelectsTheNewerDownloadedCopyAndBadgesANewerNightly() async throws {
        let first = try FakeNightlyFeed(tag: "2026.10.26.220202")
        _ = try await YtDlpUpdater(installations: installations, http: first).update()
        let model = model(try FakeNightlyFeed(tag: "2026.10.28.000000"))

        await model.launch()

        #expect(model.selection.copy.version?.tag == "2026.10.26.220202")
        #expect(model.versionLabel == "yt-dlp 2026.10.26.220202")
        #expect(model.showsBadge)
        #expect(model.message == nil)
        model.stop()
    }

    @Test func aFailedCheckStaysQuiet() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")
        feed.failure = URLError(.notConnectedToInternet)
        let model = model(feed)

        await model.launch()

        #expect(!model.showsBadge)
        #expect(model.message == nil)
        model.stop()
    }

    @Test func checksAgainWhileTheAppStaysOpen() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")
        let model = model(feed, checkInterval: .milliseconds(20))

        await model.launch()
        try await Task.sleep(for: .milliseconds(200))
        model.stop()

        #expect(feed.requested.filter { $0 == FakeNightlyFeed.api }.count >= 3)
    }

    @Test func updateInstallsSwitchesDownloadsToItAndClearsTheBadge() async throws {
        let model = model(try FakeNightlyFeed(tag: "2026.10.26.220202"))
        await model.launch()
        #expect(model.showsBadge)

        await model.update()

        #expect(model.selection.copy.version?.tag == "2026.10.26.220202")
        #expect(model.selection.copy.origin == .downloaded)
        #expect(!model.showsBadge)
        #expect(model.message == YtDlpUpdateModel.Message(text: "Updated to yt-dlp 2026.10.26.220202.", isError: false))
        model.stop()
    }

    @Test func updateWhenUpToDateSaysSo() async throws {
        let model = model(try FakeNightlyFeed(tag: "2026.10.20"))

        await model.update()

        #expect(model.selection.copy == bundled)
        #expect(model.message == YtDlpUpdateModel.Message(text: "yt-dlp 2026.10.20 is the latest.", isError: false))
    }

    @Test func aFailedUpdateKeepsTheCurrentCopyAndExplainsInPlainWords() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")
        feed.checksums = ""
        let model = model(feed)

        await model.update()

        #expect(model.selection.copy == bundled)
        #expect(model.message == YtDlpUpdateModel.Message(
            text: "The downloaded yt-dlp didn't match its checksum, so it wasn't installed. You're still on yt-dlp 2026.10.20.\nTry again later.",
            isError: true
        ))
        #expect(!model.isUpdating)
    }

    @Test func updateIsDisabledWithAHintWhileAnyDownloadRuns() async throws {
        let downloads = Downloads()
        downloads.running = true
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")
        let model = model(feed, downloads: downloads)

        #expect(!model.canUpdate)
        #expect(model.message == YtDlpUpdateModel.Message(text: "Finish or cancel the Queue to update yt-dlp.", isError: false))

        await model.update()
        #expect(feed.requested.isEmpty)
        #expect(model.selection.copy == bundled)

        downloads.running = false
        #expect(model.canUpdate)
        #expect(model.message == nil)
    }

    @Test func theQueueCountsAsDownloadingUntilEveryItemHasEnded() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "success"))
        #expect(!queue.hasActiveDownloads)

        queue.add(DownloadRequest(url: "https://youtu.be/abc123", downloadFolder: fake.downloadFolder, options: .default))
        #expect(queue.hasActiveDownloads)

        await queue.waitUntilIdle()
        #expect(!queue.hasActiveDownloads)
    }
}
