import Foundation
import Testing
@testable import YT4SCore

/// Updates yt-dlp from the real GitHub nightly channel into a temp Application Support root
/// (downloads ~55 MB). Live (see `LiveTests`); needs no bundled tool.
@Suite(.live)
struct LiveYtDlpUpdateTests {
    @Test(.timeLimit(.minutes(5)))
    func updatesFromTheRealNightlyChannel() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("yt4s-live-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("com.njpobar.YT4S/yt-dlp", isDirectory: true)
        // An old bundled floor, so whatever nightly is current counts as newer.
        let installations = YtDlpInstallations(
            root: root,
            bundled: BundledYtDlp(executable: URL(fileURLWithPath: "/nonexistent/yt-dlp_macos"), version: YtDlpVersion("2020.01.01"))
        )
        let updater = YtDlpUpdater(installations: installations, http: URLSessionHTTPClient())

        let available = try #require(try await updater.check())
        let outcome = try await updater.update()

        guard case .installed(let copy) = outcome else {
            Issue.record("expected an install, got \(outcome)")
            return
        }
        #expect(copy.version == available)
        #expect(installations.readState() == YtDlpState(active: available.tag))
        let run = try await Subprocess.run(executable: copy.executable, arguments: ["--version"])
        #expect(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == available.tag)
        // Thinned to arm64 like the bundled copy.
        let kind = try await Subprocess.run(executable: URL(fileURLWithPath: "/usr/bin/file"), arguments: ["-b", copy.executable.path])
        #expect(kind.stdout.contains("arm64") && !kind.stdout.contains("universal"))
        #expect(try await updater.update() == .upToDate(copy))
        #expect(try await updater.check() == nil)
    }
}
