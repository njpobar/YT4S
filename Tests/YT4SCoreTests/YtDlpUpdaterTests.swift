import Foundation
import Testing
@testable import YT4SCore

/// The Update yt-dlp flow against an offline fake of GitHub, with a real unzip and smoke test.
@Suite struct YtDlpUpdaterTests {
    let root: URL
    let installations: YtDlpInstallations

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-updater-\(UUID().uuidString)/yt-dlp", isDirectory: true)
        installations = YtDlpInstallations(
            root: root,
            bundled: BundledYtDlp(executable: URL(fileURLWithPath: "/nonexistent/yt-dlp_macos"), version: YtDlpVersion("2026.10.20"))
        )
    }

    private func updater(_ feed: FakeNightlyFeed) -> YtDlpUpdater {
        YtDlpUpdater(installations: installations, http: feed)
    }

    private func entries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    @Test func updateInstallsTheLatestNightlyAndMakesItActive() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")

        let outcome = try await updater(feed).update()

        let expected = YtDlpCopy(
            version: YtDlpVersion("2026.10.26.220202"),
            executable: root.appendingPathComponent("2026.10.26.220202/yt-dlp_macos"),
            origin: .downloaded
        )
        #expect(outcome == .installed(expected))
        #expect(installations.current() == expected)
        #expect(entries() == ["2026.10.26.220202", "state.json"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026.10.26.220202/_internal/base_library.zip").path))
        let smoke = try await Subprocess.run(executable: expected.executable, arguments: ["--version"])
        #expect(smoke.stdout == "2026.10.26.220202\n")
    }

    @Test func updateWhenAlreadyOnTheLatestDownloadsNothing() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.20")

        let outcome = try await updater(feed).update()

        #expect(outcome == .upToDate(installations.current()))
        #expect(feed.requested == [FakeNightlyFeed.api])
        #expect(entries() == [])
    }

    @Test func aChecksumMismatchKeepsTheCurrentVersionAndDiscardsStaging() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")
        feed.checksums = "0000000000000000000000000000000000000000000000000000000000000000  yt-dlp_macos.zip\n"
        let before = installations.current()

        await #expect(throws: YtDlpUpdateError.checksumMismatch) { try await updater(feed).update() }

        #expect(installations.current() == before)
        #expect(entries() == [])
    }

    @Test func aMissingChecksumLineIsAFailureNotAPass() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")
        feed.checksums = "13b01617c8e8fe9ec89cc063eb8fc015667562f837289ded70d8fc680646df1c  yt-dlp_macos\n"

        await #expect(throws: YtDlpUpdateError.checksumMismatch) { try await updater(feed).update() }
        #expect(entries() == [])
    }

    @Test func aCopyThatReportsTheWrongVersionFailsTheSmokeTest() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202", script: "#!/bin/sh\necho 2026.10.01\n")

        await #expect(throws: YtDlpUpdateError.smokeTestFailed) { try await updater(feed).update() }
        #expect(entries() == [])
    }

    @Test func aCopyThatCrashesFailsTheSmokeTest() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202", script: "#!/bin/sh\nkill -SEGV $$\n")

        await #expect(throws: YtDlpUpdateError.smokeTestFailed) { try await updater(feed).update() }
        #expect(entries() == [])
    }

    @Test func aFailedUpdateLeavesTheExistingDownloadsAlone() async throws {
        let good = try FakeNightlyFeed(tag: "2026.10.26.220202")
        _ = try await updater(good).update()
        let bad = try FakeNightlyFeed(tag: "2026.10.27.000000", script: "#!/bin/sh\nexit 1\n")

        await #expect(throws: YtDlpUpdateError.smokeTestFailed) { try await updater(bad).update() }

        #expect(installations.current().version?.tag == "2026.10.26.220202")
        #expect(entries() == ["2026.10.26.220202", "state.json"])
    }

    @Test func beingOfflineIsReportedAsSuch() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")
        feed.failure = URLError(.notConnectedToInternet)

        await #expect(throws: YtDlpUpdateError.offline) { try await updater(feed).update() }
    }

    @Test func aReleaseWithoutTheMacZipIsUnusable() async throws {
        final class NoZip: HTTPClient {
            func data(from url: URL) async throws -> Data { Data(#"{"tag_name": "2026.10.26.220202", "assets": []}"#.utf8) }
            func download(from url: URL, to destination: URL) async throws { throw URLError(.fileDoesNotExist) }
        }
        let updater = YtDlpUpdater(installations: installations, http: NoZip())

        await #expect(throws: YtDlpUpdateError.releaseUnusable) { try await updater.update() }
    }

    @Test func aTagThatIsNotAVersionIsRejectedBeforeAnythingIsWritten() async throws {
        final class BadTag: HTTPClient {
            func data(from url: URL) async throws -> Data { Data(#"{"tag_name": "../../evil", "assets": []}"#.utf8) }
            func download(from url: URL, to destination: URL) async throws {}
        }
        let updater = YtDlpUpdater(installations: installations, http: BadTag())

        await #expect(throws: YtDlpUpdateError.releaseUnusable) { try await updater.update() }
        #expect(entries() == [])
    }

    // MARK: Check (badge only, never installs)

    @Test func checkOffersANewerNightlyWithoutDownloadingIt() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")

        let available = try await updater(feed).check()

        #expect(available == YtDlpVersion("2026.10.26.220202"))
        #expect(feed.requested == [FakeNightlyFeed.api])
        #expect(entries() == [])
    }

    @Test func checkOffersNothingWhenUpToDate() async throws {
        let feed = try FakeNightlyFeed(tag: "2026.10.20")
        #expect(try await updater(feed).check() == nil)
    }

    @Test func checkOffersNothingWhileRolledBack() async throws {
        try installations.writeState(YtDlpState(pinned: true))
        let feed = try FakeNightlyFeed(tag: "2026.10.26.220202")

        #expect(try await updater(feed).check() == nil)
        // A click on Update still installs it and clears the pin.
        _ = try await updater(feed).update()
        #expect(installations.readState().pinned == false)
    }
}
