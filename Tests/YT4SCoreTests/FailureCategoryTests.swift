import Foundation
import Testing
@testable import YT4SCore

/// Categorizing a failed yt-dlp run from its stderr.
///
/// `Fixtures/yt-dlp-stderr/*.stderr` were captured from the bundled yt-dlp 2026.10.26.220202
/// (network failures forced with an unreachable `--proxy`, disk ones with a read-only folder and a
/// 600 KB disk image). `from-source/` holds the ones not obtainable from here (private, region,
/// bot-check, nsig, 403...), written from that version's source error strings.
@Suite struct FailureCategoryTests {
    @Test(arguments: [
        ("unavailable-video", FailureCategory.unavailable),
        ("age-restricted", .unavailable),
        ("connection-refused", .network),
        ("dns-failure", .network),
        ("disk-full", .disk),
        ("read-only-folder", .disk),
    ])
    func capturedFixtures(name: String, expected: FailureCategory) throws {
        #expect(FailureCategory(stderr: try StderrFixture.text(name), termination: .exited(1)) == expected)
    }

    @Test(arguments: [
        ("private-video", FailureCategory.unavailable),
        ("removed-by-uploader", .unavailable),
        ("account-terminated", .unavailable),
        ("copyright-claim", .unavailable),
        ("members-only", .unavailable),
        ("region-blocked", .regionBlocked),
        ("geo-restricted-generic", .regionBlocked),
        ("bot-check", .looksOutdated),
        ("n-challenge-failed", .looksOutdated),
        ("nsig-extraction-failed", .looksOutdated),
        ("unable-to-extract-player-response", .looksOutdated),
        ("no-player-response", .looksOutdated),
        ("http-403-video-data", .looksOutdated),
        ("fragment-403", .looksOutdated),
        ("read-timeout", .network),
        ("connection-reset", .network),
        ("rate-limited", .unknown),
        ("postprocessing-failed", .unknown),
    ])
    func fixturesFromYtDlpSource(name: String, expected: FailureCategory) throws {
        #expect(FailureCategory(stderr: try StderrFixture.text("from-source/" + name), termination: .exited(1)) == expected)
    }

    @Test func aNetworkErrorThatAsksToReportABugIsStillNetwork() throws {
        // yt-dlp tacks "please report this issue ... yt-dlp -U" onto connection failures too.
        let stderr = try StderrFixture.text("connection-refused")
        #expect(stderr.contains("Confirm you are on the latest version"))
        #expect(FailureCategory(stderr: stderr, termination: .exited(1)) == .network)
    }

    @Test func warningsDoNotOverrideTheError() {
        let stderr = """
        WARNING: [youtube] abc: n challenge solving failed: Some formats may be missing.
        ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader
        """
        #expect(FailureCategory(stderr: stderr, termination: .exited(1)) == .unavailable)
    }

    @Test func aCrashOrALaunchFailureWithoutAnErrorLineIsUnknown() {
        #expect(FailureCategory(stderr: "Traceback (most recent call last):", termination: .signaled(SIGSEGV)) == .unknown)
        #expect(FailureCategory(stderr: "The file doesn't exist.", termination: nil) == .unknown)
        #expect(FailureCategory(stderr: "", termination: .exited(1)) == .unknown)
    }

    @Test func aSignalledRunIsCategorizedByItsErrorLines() {
        let stderr = """
        ERROR: [download] Got error: HTTPSConnectionPool(host='rr1.googlevideo.com', port=443): Read timed out.
        Traceback (most recent call last):
        """
        #expect(FailureCategory(stderr: stderr, termination: .signaled(SIGSEGV)) == .network)
    }

    @Test func aSignalledRunIgnoresMarkersOutsideErrorLines() {
        // A crash dump can mention anything; only what yt-dlp reported as the error counts.
        let stderr = "Traceback (most recent call last):\n  File \"nsig.py\", line 3, in <module>"
        #expect(FailureCategory(stderr: stderr, termination: .signaled(SIGSEGV)) == .unknown)
    }

    @Test func onlyUnavailableAndRegionBlockedCannotBeRetried() {
        #expect(FailureCategory.allCases.filter { !$0.isRetryable } == [.unavailable, .regionBlocked])
    }
}

enum StderrFixture {
    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "stderr", subdirectory: "Fixtures/yt-dlp-stderr") else {
            throw FixtureError.missing("Fixtures/yt-dlp-stderr/\(name).stderr")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
