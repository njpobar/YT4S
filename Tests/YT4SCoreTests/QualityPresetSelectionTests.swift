import Foundation
import Testing
@testable import YT4SCore

/// Which formats each Quality preset really picks: the real bundled yt-dlp (offline,
/// `--load-info-json --simulate`) runs `DownloadArguments.formatSelection` on a video with
/// made-up formats. Runs when `vendor/` holds the tools or `YT4S_LIVE_APP` names a built app.
@Suite(.enabled(if: LocalYtDlp.tools != nil))
struct QualityPresetSelectionTests {
    /// One video stream: height and codec (`avc1` = H.264, `vp9`, `av01`).
    struct Stream {
        var height: Int
        var codec: String
    }

    private func selected(_ quality: QualityPreset, from streams: [Stream]) async throws -> String {
        let tools = try #require(LocalYtDlp.tools)
        let info = FileManager.default.temporaryDirectory.appendingPathComponent("yt4s-quality-\(UUID().uuidString).info.json")
        try Self.infoJSON(streams).write(to: info)
        defer { try? FileManager.default.removeItem(at: info) }
        let options = DownloadOptions(format: .video, quality: quality, naming: .title)
        let result = try await Subprocess.run(
            executable: tools.ytDlp,
            arguments: YtDlpCommand(tools: tools).arguments(
                ["--load-info-json", info.path, "--simulate", "--print", "format_id"] + DownloadArguments.formatSelection(options)
            )
        )
        #expect(result.termination == .exited(0), "\(result.stderr)")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func aCapTakesTheBestStreamAtOrBelowIt() async throws {
        let streams = [Stream(height: 1080, codec: "avc1"), Stream(height: 720, codec: "avc1"), Stream(height: 480, codec: "avc1")]
        #expect(try await selected(.p720, from: streams) == "720-avc1+aac")
        #expect(try await selected(.p1080, from: streams) == "1080-avc1+aac")
    }

    @Test func aCapPrefersAnyCodecAtOrBelowItOverH264AboveIt() async throws {
        let streams = [Stream(height: 1080, codec: "avc1"), Stream(height: 480, codec: "vp9")]
        #expect(try await selected(.p720, from: streams) == "480-vp9+aac")
    }

    @Test func withNothingAtOrBelowTheCapItTakesTheSmallestAboveIt() async throws {
        let streams = [Stream(height: 2160, codec: "av01"), Stream(height: 1440, codec: "vp9"), Stream(height: 1080, codec: "vp9")]
        #expect(try await selected(.p720, from: streams) == "1080-vp9+aac")
    }

    @Test func withNothingAtOrBelowTheCapH264StillWins() async throws {
        let streams = [Stream(height: 2160, codec: "vp9"), Stream(height: 1440, codec: "avc1"), Stream(height: 1080, codec: "vp9")]
        #expect(try await selected(.p720, from: streams) == "1440-avc1+aac")
    }

    @Test func bestPrefersH264AtTheHighestResolution() async throws {
        let streams = [Stream(height: 2160, codec: "av01"), Stream(height: 1080, codec: "avc1"), Stream(height: 720, codec: "avc1")]
        #expect(try await selected(.best, from: streams) == "1080-avc1+aac")
    }

    private static func infoJSON(_ streams: [Stream]) throws -> Data {
        var formats: [[String: Any]] = streams.map { stream in
            [
                "format_id": "\(stream.height)-\(stream.codec)",
                "url": "https://example.invalid/\(stream.height)-\(stream.codec)",
                "ext": stream.codec == "avc1" ? "mp4" : "webm",
                "vcodec": ["avc1": "avc1.640028", "vp9": "vp9", "av01": "av01.0.08M.08"][stream.codec]!,
                "acodec": "none",
                "height": stream.height,
                "width": stream.height * 16 / 9,
                "tbr": stream.height,
                "protocol": "https",
            ]
        }
        formats += [
            ["format_id": "aac", "url": "https://example.invalid/aac", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 128, "protocol": "https"],
            ["format_id": "opus", "url": "https://example.invalid/opus", "ext": "webm", "vcodec": "none", "acodec": "opus", "abr": 160, "protocol": "https"],
        ]
        let info: [String: Any] = [
            "id": "dQw4w9WgXcQ", "title": "Sample", "extractor": "youtube", "extractor_key": "Youtube",
            "webpage_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "formats": formats,
        ]
        return try JSONSerialization.data(withJSONObject: info)
    }
}
