import Foundation
import Testing
@testable import YT4SCore

/// The downloaded yt-dlp copies under Application Support and the `state.json` pointer.
@Suite struct YtDlpInstallationsTests {
    let sandbox: URL
    let root: URL
    let bundledExecutable: URL

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-installs-\(UUID().uuidString)", isDirectory: true)
        root = sandbox.appendingPathComponent("Application Support/com.njpobar.YT4S/yt-dlp", isDirectory: true)
        bundledExecutable = sandbox.appendingPathComponent("YT4S.app/Contents/Resources/bin/yt-dlp/yt-dlp_macos")
    }

    private func installations(bundled tag: String? = "2026.10.20") -> YtDlpInstallations {
        YtDlpInstallations(
            root: root,
            bundled: BundledYtDlp(executable: bundledExecutable, version: tag.flatMap(YtDlpVersion.init))
        )
    }

    /// A downloaded copy as the updater leaves it: `<root>/<tag>/yt-dlp_macos`.
    private func download(_ tag: String) throws {
        let directory = root.appendingPathComponent(tag, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho \(tag)\n".utf8).write(to: directory.appendingPathComponent("yt-dlp_macos"))
    }

    private func writeState(_ json: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: root.appendingPathComponent("state.json"))
    }

    private func downloadedTags() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0 != "state.json" }
            .sorted()
    }

    private func stage(_ tag: String, in installations: YtDlpInstallations) throws -> URL {
        let staging = try installations.makeStagingDirectory()
        try Data("#!/bin/sh\necho \(tag)\n".utf8).write(to: staging.appendingPathComponent("yt-dlp_macos"))
        return staging
    }

    // MARK: Launch: newer of downloaded active and bundled

    @Test func withNothingDownloadedTheBundledCopyIsUsed() throws {
        let copy = try installations().prepareAtLaunch()
        #expect(copy == YtDlpCopy(version: YtDlpVersion("2026.10.20"), executable: bundledExecutable, origin: .bundled))
    }

    @Test func aDownloadedActiveCopyNewerThanBundledIsUsed() throws {
        try download("2026.10.26.220202")
        try writeState(#"{"active": "2026.10.26.220202"}"#)

        let copy = try installations().prepareAtLaunch()

        #expect(copy.origin == .downloaded)
        #expect(copy.version?.tag == "2026.10.26.220202")
        #expect(copy.executable == root.appendingPathComponent("2026.10.26.220202/yt-dlp_macos"))
    }

    @Test func aBundledCopyNewerThanTheDownloadedActiveWinsAndOlderDownloadsArePruned() throws {
        // After an app update shipped a newer floor than what was downloaded before.
        try download("2026.10.10.000000")
        try download("2026.10.15.000000")
        try writeState(#"{"active": "2026.10.15.000000", "previous": "2026.10.10.000000"}"#)

        let installations = installations(bundled: "2026.10.20")
        let copy = try installations.prepareAtLaunch()

        #expect(copy.origin == .bundled)
        #expect(try downloadedTags() == [])
        #expect(installations.readState() == YtDlpState())
    }

    @Test func pruningKeepsDownloadsNewerThanBundledAndForgetsOnlyThePrunedOnes() throws {
        try download("2026.10.10.000000")
        try download("2026.10.26.220202")
        try writeState(#"{"active": "2026.10.26.220202", "previous": "2026.10.10.000000"}"#)

        let installations = installations(bundled: "2026.10.20")
        let copy = try installations.prepareAtLaunch()

        #expect(copy.version?.tag == "2026.10.26.220202")
        #expect(try downloadedTags() == ["2026.10.26.220202"])
        #expect(installations.readState() == YtDlpState(active: "2026.10.26.220202", previous: nil))
    }

    @Test func aMissingActiveDirectoryFallsBackToBundledAndIsForgotten() throws {
        try writeState(#"{"active": "2026.10.26.220202"}"#)

        let installations = installations()
        let copy = try installations.prepareAtLaunch()

        #expect(copy.origin == .bundled)
        #expect(installations.readState() == YtDlpState())
    }

    @Test func aCorruptStateFileCountsAsNothingDownloaded() throws {
        try download("2026.10.26.220202")
        try writeState("{not json")

        let installations = installations()
        let copy = try installations.prepareAtLaunch()

        #expect(copy.origin == .bundled)
        // Unreferenced copies are not kept around.
        #expect(try downloadedTags() == [])
    }

    @Test func leftoverStagingAndUnreferencedCopiesAreRemovedAtLaunch() throws {
        try download("2026.10.26.220202")
        try download("2026.10.27.000000")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".staging-1234"), withIntermediateDirectories: true)
        try writeState(#"{"active": "2026.10.27.000000"}"#)

        _ = try installations().prepareAtLaunch()

        #expect(try downloadedTags() == ["2026.10.27.000000"])
    }

    @Test func withAnUnknownBundledVersionADownloadedActiveCopyIsUsedAndNothingIsPruned() throws {
        try download("2026.10.10.000000")
        try download("2026.10.26.220202")
        try writeState(#"{"active": "2026.10.26.220202", "previous": "2026.10.10.000000"}"#)

        let copy = try installations(bundled: nil).prepareAtLaunch()

        #expect(copy.version?.tag == "2026.10.26.220202")
        #expect(try downloadedTags() == ["2026.10.10.000000", "2026.10.26.220202"])
    }

    @Test func thePinFromRollBackSurvivesLaunch() throws {
        try download("2026.10.26.220202")
        try download("2026.10.27.000000")
        try writeState(#"{"active": "2026.10.26.220202", "previous": "2026.10.27.000000", "pinned": true}"#)

        let installations = installations()
        _ = try installations.prepareAtLaunch()

        #expect(installations.readState() == YtDlpState(active: "2026.10.26.220202", previous: "2026.10.27.000000", pinned: true))
    }

    // MARK: Installing a staged copy: active + one previous

    @Test func installingTheFirstDownloadMakesItActiveWithNoPrevious() throws {
        let installations = installations()
        let staging = try stage("2026.10.26.220202", in: installations)

        let copy = try installations.install(staging, as: #require(YtDlpVersion("2026.10.26.220202")))

        #expect(copy == YtDlpCopy(
            version: YtDlpVersion("2026.10.26.220202"),
            executable: root.appendingPathComponent("2026.10.26.220202/yt-dlp_macos"),
            origin: .downloaded
        ))
        #expect(installations.readState() == YtDlpState(active: "2026.10.26.220202", previous: nil))
        #expect(try downloadedTags() == ["2026.10.26.220202"])
        #expect(try installations.prepareAtLaunch() == copy)
    }

    @Test func installingKeepsTheOldActiveAsPreviousAndDropsTheOneBefore() throws {
        try download("2026.10.21.000000")
        try download("2026.10.26.220202")
        try writeState(#"{"active": "2026.10.26.220202", "previous": "2026.10.21.000000"}"#)
        let installations = installations()

        let staging = try stage("2026.10.28.000000", in: installations)
        _ = try installations.install(staging, as: #require(YtDlpVersion("2026.10.28.000000")))

        #expect(installations.readState() == YtDlpState(active: "2026.10.28.000000", previous: "2026.10.26.220202"))
        #expect(try downloadedTags() == ["2026.10.26.220202", "2026.10.28.000000"])
    }

    @Test func installingClearsTheRollBackPin() throws {
        try download("2026.10.26.220202")
        try download("2026.10.27.000000")
        try writeState(#"{"active": "2026.10.26.220202", "previous": "2026.10.27.000000", "pinned": true}"#)
        let installations = installations()

        // Update again offers the same newest tag that was rolled back from: it is replaced.
        let staging = try stage("2026.10.27.000000", in: installations)
        _ = try installations.install(staging, as: #require(YtDlpVersion("2026.10.27.000000")))

        #expect(installations.readState() == YtDlpState(active: "2026.10.27.000000", previous: "2026.10.26.220202", pinned: false))
        #expect(try downloadedTags() == ["2026.10.26.220202", "2026.10.27.000000"])
        let script = try String(contentsOf: root.appendingPathComponent("2026.10.27.000000/yt-dlp_macos"), encoding: .utf8)
        #expect(script.contains("echo 2026.10.27.000000"))
    }

    @Test func stateIsWrittenAsVersionedJSON() throws {
        let installations = installations()
        let staging = try stage("2026.10.26.220202", in: installations)
        _ = try installations.install(staging, as: #require(YtDlpVersion("2026.10.26.220202")))

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any]
        #expect(json?["schema"] as? Int == 1)
        #expect(json?["active"] as? String == "2026.10.26.220202")
        #expect(json?["pinned"] as? Bool == false)
    }

    // MARK: Fallback chain (used by Roll back / launch fallback, #30)

    @Test func theFallbackChainIsActiveThenPreviousThenBundled() throws {
        try download("2026.10.26.220202")
        try download("2026.10.27.000000")
        try writeState(#"{"active": "2026.10.27.000000", "previous": "2026.10.26.220202"}"#)

        let chain = installations().fallbackChain()

        #expect(chain.map(\.origin) == [.downloaded, .downloaded, .bundled])
        #expect(chain.map(\.version?.tag) == ["2026.10.27.000000", "2026.10.26.220202", "2026.10.20"])
    }

    @Test func theFallbackChainSkipsCopiesThatAreNotNewerThanBundled() throws {
        try download("2026.10.26.220202")
        try writeState(#"{"active": "2026.10.26.220202"}"#)

        let chain = installations(bundled: "2026.10.30").fallbackChain()

        #expect(chain.map(\.origin) == [.bundled])
    }

    // MARK: Roll back

    private var bundledCopy: YtDlpCopy {
        YtDlpCopy(version: YtDlpVersion("2026.10.20"), executable: bundledExecutable, origin: .bundled)
    }

    @Test func afterTheFirstUpdateRollBackReturnsToTheBundledCopyAndPinsIt() throws {
        let installations = installations()
        let staging = try stage("2026.10.26.220202", in: installations)
        _ = try installations.install(staging, as: #require(YtDlpVersion("2026.10.26.220202")))
        #expect(installations.rollBackTarget() == bundledCopy)

        let copy = try installations.rollBack()

        #expect(copy == bundledCopy)
        #expect(installations.current() == bundledCopy)
        #expect(installations.readState() == YtDlpState(active: nil, previous: "2026.10.26.220202", pinned: true))
        // The copy rolled back from is kept, so Update yt-dlp can return to it.
        #expect(try downloadedTags() == ["2026.10.26.220202"])
    }

    @Test func rollBackSwapsToThePreviousDownloadAndKeepsTheNewerOneAsPrevious() throws {
        try download("2026.10.26.220202")
        try download("2026.10.27.000000")
        try writeState(#"{"active": "2026.10.27.000000", "previous": "2026.10.26.220202"}"#)
        let installations = installations()

        let copy = try installations.rollBack()

        #expect(copy.version?.tag == "2026.10.26.220202")
        #expect(copy.origin == .downloaded)
        #expect(installations.readState() == YtDlpState(active: "2026.10.26.220202", previous: "2026.10.27.000000", pinned: true))
        #expect(try installations.prepareAtLaunch() == copy)
    }

    @Test func thereIsNothingToRollBackToOnTheBundledCopyOrWhilePinned() throws {
        let installations = installations()
        #expect(installations.rollBackTarget() == nil)
        #expect(throws: YtDlpRollBackError.nothingToRollBackTo) { try installations.rollBack() }

        try download("2026.10.26.220202")
        try writeState(#"{"active": "2026.10.26.220202"}"#)
        try installations.rollBack()

        #expect(installations.rollBackTarget() == nil)
    }

    @Test func aRollBackToTheBundledCopySurvivesLaunch() throws {
        try download("2026.10.26.220202")
        try writeState(#"{"previous": "2026.10.26.220202", "pinned": true}"#)
        let installations = installations()

        #expect(try installations.prepareAtLaunch() == bundledCopy)
        #expect(installations.readState() == YtDlpState(active: nil, previous: "2026.10.26.220202", pinned: true))
    }

    @Test func installingAfterARollBackToBundledClearsThePin() throws {
        try download("2026.10.26.220202")
        try writeState(#"{"previous": "2026.10.26.220202", "pinned": true}"#)
        let installations = installations()

        let staging = try stage("2026.10.26.220202", in: installations)
        _ = try installations.install(staging, as: #require(YtDlpVersion("2026.10.26.220202")))

        #expect(installations.readState() == YtDlpState(active: "2026.10.26.220202", previous: nil, pinned: false))
        #expect(installations.rollBackTarget() == bundledCopy)
    }

    @Test func aPinIsDroppedOnceTheCopyRolledBackFromIsOlderThanANewBundledCopy() throws {
        // An app update shipped a bundled floor newer than both downloads.
        try download("2026.10.26.220202")
        try download("2026.10.27.000000")
        try writeState(#"{"active": "2026.10.26.220202", "previous": "2026.10.27.000000", "pinned": true}"#)
        let installations = installations(bundled: "2026.10.28")

        #expect(try installations.prepareAtLaunch().origin == .bundled)
        #expect(installations.readState() == YtDlpState())
    }

    @Test func whenTheActiveDirectoryIsGoneThePreviousDownloadTakesOver() throws {
        try download("2026.10.26.220202")
        try writeState(#"{"active": "2026.10.27.000000", "previous": "2026.10.26.220202"}"#)
        let installations = installations()

        #expect(try installations.prepareAtLaunch().version?.tag == "2026.10.26.220202")
        #expect(installations.readState() == YtDlpState(active: "2026.10.26.220202"))
    }

    @Test func afterRollingBackToBundledTheChainFallsBackToTheNewerDownload() throws {
        try download("2026.10.26.220202")
        try writeState(#"{"previous": "2026.10.26.220202", "pinned": true}"#)

        let chain = installations().fallbackChain()

        #expect(chain.map(\.version?.tag) == ["2026.10.20", "2026.10.26.220202"])
    }
}
