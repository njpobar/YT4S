import Foundation

/// Locations of the external tools yt-dlp needs.
public struct BundledTools: Equatable, Sendable {
    /// The `yt-dlp_macos` executable (inside its onedir folder).
    public var ytDlp: URL
    /// Folder holding both `ffmpeg` and `ffprobe`.
    public var ffmpegDirectory: URL
    /// The `deno` executable.
    public var deno: URL

    public init(ytDlp: URL, ffmpegDirectory: URL, deno: URL) {
        self.ytDlp = ytDlp
        self.ffmpegDirectory = ffmpegDirectory
        self.deno = deno
    }

    /// Layout produced by `scripts/build-app.sh`:
    /// `Contents/Resources/bin/{yt-dlp/yt-dlp_macos, ffmpeg, ffprobe, deno}`.
    public init(resourcesDirectory: URL) {
        let bin = resourcesDirectory.appendingPathComponent("bin", isDirectory: true)
        self.init(
            ytDlp: bin.appendingPathComponent("yt-dlp/yt-dlp_macos"),
            ffmpegDirectory: bin,
            deno: bin.appendingPathComponent("deno")
        )
    }
}

/// Builds yt-dlp argv with the flags every invocation must carry (ADR 0002):
/// ignore user config, never self-update, and use only the bundled ffmpeg and Deno.
public struct YtDlpCommand: Sendable {
    public var tools: BundledTools

    public init(tools: BundledTools) {
        self.tools = tools
    }

    public func arguments(_ extra: [String]) -> [String] {
        [
            "--ignore-config",
            "--no-update",
            "--ffmpeg-location", tools.ffmpegDirectory.path,
            "--js-runtimes", "deno:\(tools.deno.path)",
        ] + extra
    }
}
