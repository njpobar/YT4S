import Foundation
import Testing
@testable import YT4SCore

/// At launch, a yt-dlp copy that cannot start is skipped: active, then previous, then bundled.
@Suite struct YtDlpLaunchFallbackTests {
    let sandbox: URL
    let root: URL
    let bundledExecutable: URL
    let fake: FakeYtDlp

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-fallback-\(UUID().uuidString)", isDirectory: true)
        root = sandbox.appendingPathComponent("yt-dlp", isDirectory: true)
        bundledExecutable = sandbox.appendingPathComponent("YT4S.app/Contents/Resources/bin/yt-dlp/yt-dlp_macos")
        fake = try FakeYtDlp()
    }

    private var installations: YtDlpInstallations {
        YtDlpInstallations(root: root, bundled: BundledYtDlp(executable: bundledExecutable, version: YtDlpVersion("2026.10.20")))
    }

    private func updater() -> YtDlpUpdater {
        YtDlpUpdater(installations: installations, http: UnreachableHTTPClient(), smokeTestTimeout: .seconds(10))
    }

    /// A copy that runs the fake yt-dlp in `scenario` (`launch-crash` segfaults on start).
    private func place(_ tag: String, at executable: URL, scenario: String) throws {
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = "#!/bin/sh\nYT4S_FAKE_SCENARIO=\(scenario) YT4S_FAKE_VERSION=\(tag) exec '\(fake.executable.path)' \"$@\"\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private func download(_ tag: String, scenario: String) throws {
        try place(tag, at: root.appendingPathComponent("\(tag)/yt-dlp_macos"), scenario: scenario)
    }

    private func bundled(scenario: String) throws {
        try place("2026.10.20", at: bundledExecutable, scenario: scenario)
    }

    private func setUp(active: String, previous: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try installations.writeState(YtDlpState(active: active, previous: previous))
    }

    @Test func theActiveCopyIsUsedWhenItStarts() async throws {
        try download("2026.10.27.000000", scenario: "success")
        try download("2026.10.26.220202", scenario: "success")
        try bundled(scenario: "success")
        try setUp(active: "2026.10.27.000000", previous: "2026.10.26.220202")

        #expect(await updater().firstLaunchableCopy()?.version?.tag == "2026.10.27.000000")
    }

    @Test func aCrashingActiveCopyFallsBackToThePreviousOne() async throws {
        try download("2026.10.27.000000", scenario: "launch-crash")
        try download("2026.10.26.220202", scenario: "success")
        try bundled(scenario: "success")
        try setUp(active: "2026.10.27.000000", previous: "2026.10.26.220202")

        #expect(await updater().firstLaunchableCopy()?.version?.tag == "2026.10.26.220202")
    }

    @Test func whenBothDownloadsCrashTheBundledCopyIsUsed() async throws {
        try download("2026.10.27.000000", scenario: "launch-crash")
        try download("2026.10.26.220202", scenario: "launch-crash")
        try bundled(scenario: "success")
        try setUp(active: "2026.10.27.000000", previous: "2026.10.26.220202")

        let copy = await updater().firstLaunchableCopy()

        #expect(copy?.origin == .bundled)
        // Falling back changes only this session: the pointer still names the active copy.
        #expect(installations.readState().active == "2026.10.27.000000")
    }

    @Test func whenEveryCopyCrashesThereIsNoneToRun() async throws {
        try download("2026.10.27.000000", scenario: "launch-crash")
        try download("2026.10.26.220202", scenario: "launch-crash")
        try bundled(scenario: "launch-crash")
        try setUp(active: "2026.10.27.000000", previous: "2026.10.26.220202")

        #expect(await updater().firstLaunchableCopy() == nil)
    }

    @Test func aMissingBundledCopyCountsAsDamaged() async throws {
        #expect(await updater().firstLaunchableCopy() == nil)
    }
}

/// For flows that must not touch the network.
struct UnreachableHTTPClient: HTTPClient {
    func data(from url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    func download(from url: URL, to destination: URL) async throws { throw URLError(.notConnectedToInternet) }
}
