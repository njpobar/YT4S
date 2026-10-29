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
}
