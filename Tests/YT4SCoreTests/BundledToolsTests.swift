import Foundation
import Testing
@testable import YT4SCore

@Suite struct BundledToolsTests {
    @Test func resolvesTheLayoutBuiltByBuildAppScript() {
        let tools = BundledTools(resourcesDirectory: URL(fileURLWithPath: "/Applications/YT4S.app/Contents/Resources"))

        #expect(tools.ytDlp.path == "/Applications/YT4S.app/Contents/Resources/bin/yt-dlp/yt-dlp_macos")
        #expect(tools.ffmpegDirectory.path == "/Applications/YT4S.app/Contents/Resources/bin")
        #expect(tools.deno.path == "/Applications/YT4S.app/Contents/Resources/bin/deno")
    }

    @Test func theBundledYtDlpVersionComesFromTheFileBuildAppWrites() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("yt4s-resources-\(UUID().uuidString)")
        let bin = resources.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("2026.10.26.220202\n".utf8).write(to: bin.appendingPathComponent("yt-dlp-version"))

        let bundled = BundledYtDlp(resourcesDirectory: resources)

        #expect(bundled.version?.tag == "2026.10.26.220202")
        #expect(bundled.executable == bin.appendingPathComponent("yt-dlp/yt-dlp_macos"))
    }

    @Test func withoutTheVersionFileTheBundledVersionIsUnknown() {
        let bundled = BundledYtDlp(resourcesDirectory: URL(fileURLWithPath: "/nonexistent/Resources"))
        #expect(bundled.version == nil)
    }
}
