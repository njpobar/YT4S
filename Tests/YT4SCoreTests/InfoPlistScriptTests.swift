import Foundation
import Testing
@testable import YT4SCore

/// `scripts/write-info-plist.sh`, which `build-app.sh` uses for `YT4S.app/Contents/Info.plist`.
@Suite struct InfoPlistScriptTests {
    @Test func configuresSparkleForClickOnlyUpdatesFromTheLatestRelease() async throws {
        let plist = try await writePlist(environment: ["YT4S_SPARKLE_PUBLIC_KEY": "dGVzdC1wdWJsaWMta2V5LXRlc3QtcHVibGljLWtleSE="])

        #expect(try await value("CFBundleShortVersionString", plist) == "1.2.3")
        #expect(try await value("CFBundleVersion", plist) == "42")
        #expect(try await value("SUFeedURL", plist) == "https://github.com/njpobar/YT4S/releases/latest/download/appcast.xml")
        #expect(try await value("SUPublicEDKey", plist) == "dGVzdC1wdWJsaWMta2V5LXRlc3QtcHVibGljLWtleSE=")
        // The app schedules its own launch and daily checks and installs only on a click.
        #expect(try await value("SUEnableAutomaticChecks", plist) == "false")
        #expect(try await value("SUAutomaticallyUpdate", plist) == "false")
        #expect(try await value("SUAllowsAutomaticUpdates", plist) == "false")
        // Check the EdDSA signature on the zip before unarchiving anything.
        #expect(try await value("SUVerifyUpdateBeforeExtraction", plist) == "true")
    }

    @Test func neverSetsFileQuarantine() async throws {
        let plist = try await writePlist(environment: ["YT4S_SPARKLE_PUBLIC_KEY": "a2V5"])

        let text = try String(contentsOf: plist, encoding: .utf8)
        #expect(!text.contains("LSFileQuarantineEnabled"))
    }

    @Test func usesTheCheckedInPublicKeyByDefault() async throws {
        let checkedIn = try String(contentsOf: Self.repoRoot.appendingPathComponent("config/sparkle-public-key"), encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }.joined()
            .trimmingCharacters(in: .whitespaces)

        let plist = try await writePlist()

        if checkedIn.isEmpty {
            #expect(try await value("SUPublicEDKey", plist) == nil)
        } else {
            #expect(try await value("SUPublicEDKey", plist) == checkedIn)
        }
    }

    @Test func aLocalTestBuildCanPointAtAnotherFeed() async throws {
        let plist = try await writePlist(environment: ["YT4S_FEED_URL": "http://127.0.0.1:8123/appcast.xml"])

        #expect(try await value("SUFeedURL", plist) == "http://127.0.0.1:8123/appcast.xml")
    }

    // MARK: - Helpers

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func writePlist(environment: [String: String] = [:]) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yt4s-plist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist = dir.appendingPathComponent("Info.plist")
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        let result = try await Subprocess.run(
            executable: Self.repoRoot.appendingPathComponent("scripts/write-info-plist.sh"),
            arguments: [plist.path, "1.2.3", "42"],
            environment: env
        )
        #expect(result.termination == .exited(0), "\(result.stderr)")
        return plist
    }

    /// The plist value as text (`plutil -extract ... raw`), or nil when the key is absent.
    private func value(_ key: String, _ plist: URL) async throws -> String? {
        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/plutil"),
            arguments: ["-extract", key, "raw", plist.path]
        )
        guard result.termination == .exited(0) else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
