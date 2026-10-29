import Foundation
import Testing
@testable import YT4SCore

/// The custom Naming pattern preview, rendered offline by the real bundled yt-dlp from sample
/// metadata ("My Video" by "Some Channel", 2026-10-12, item 1 of 12 in "My Playlist"): the same
/// template language and the same details line as a real download. Runs when the repo's
/// `vendor/` holds the tools (run `scripts/fetch-deps.sh`), or `YT4S_REAL_TOOLS` names them.
/// The real yt-dlp for offline tests: `YT4S_REAL_TOOLS` (a folder in the app's `bin` layout), else
/// the repo's `vendor/`. `nil` when neither has it.
enum LocalYtDlp {
    static var tools: BundledTools? {
        if let bin = ProcessInfo.processInfo.environment["YT4S_REAL_TOOLS"] {
            let folder = URL(fileURLWithPath: bin, isDirectory: true)
            return BundledTools(
                ytDlp: folder.appendingPathComponent("yt-dlp/yt-dlp_macos"),
                ffmpegDirectory: folder,
                deno: folder.appendingPathComponent("deno")
            )
        }
        let vendor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor", isDirectory: true)
        let tools = BundledTools(
            ytDlp: vendor.appendingPathComponent("yt-dlp/yt-dlp_macos"),
            ffmpegDirectory: vendor.appendingPathComponent("ffmpeg", isDirectory: true),
            deno: vendor.appendingPathComponent("deno/deno")
        )
        return FileManager.default.isExecutableFile(atPath: tools.ytDlp.path) ? tools : nil
    }

}

@Suite(.enabled(if: LocalYtDlp.tools != nil), .serialized)
struct CustomNamePreviewTests {
    private func preview(_ template: String, format: Format = .video) async throws -> CustomNamePreview {
        await CustomNamePreviewer(runner: YtDlpRunner(tools: try #require(LocalYtDlp.tools))).preview(template, format: format)
    }

    @Test(arguments: [
        ("%(channel)s/%(title)s.%(ext)s", "Some Channel/My Video.mp4"),
        ("%(upload_date>%Y)s/%(upload_date>%Y-%m-%d)s %(title)s", "2026/2026-10-12 My Video.mp4"),
        ("%(playlist_title)s/%(playlist_index)03d - %(title)s", "My Playlist/001 - My Video.mp4"),
        ("%(series|No series)s - %(title).2s [%(id)s]", "No series - My [dQw4w9WgXcQ].mp4"),
        ("100%% %(title)s", "100% My Video.mp4"),
    ])
    func rendersTheTemplateWithTheFormatsExtension(template: String, expected: String) async throws {
        #expect(try await preview(template) == .example(expected))
    }

    @Test func mp3GetsTheMP3Extension() async throws {
        #expect(try await preview("%(title)s.%(ext)s", format: .mp3) == .example("My Video.mp3"))
    }

    @Test func aSlashInsideAValueIsNotAFolderButOneInTheTemplateIs() async throws {
        #expect(try await preview("%(channel)s/%(upload_date>%Y/%m)s") == .example("Some Channel/2026-10.mp4"))
    }

    @Test func theResultGetsThePresetCleanup() async throws {
        #expect(try await preview("../%(title)s: 🎬 part") == .example("My Video - part.mp4"))
    }

    @Test func anEmptyResultFallsBackToTheVideoID() async throws {
        #expect(try await preview("%(channel)s/") == .example("Some Channel/dQw4w9WgXcQ.mp4"))
    }

    @Test(arguments: [
        ("%(title", "incomplete format key"),
        ("%(title)z", "unsupported format character 'z' (0x7a)"),
    ])
    func flagsAnInvalidTemplateWithYtDlpsReason(template: String, reason: String) async throws {
        #expect(try await preview(template) == .invalid("Invalid template: \(reason)"))
    }

    @Test func flagsAnEmptyTemplate() async throws {
        #expect(try await preview("  ") == .invalid("Type a yt-dlp output template, e.g. \(CustomNamingTemplate.starter)"))
    }
}
