import Foundation

/// Whether a download is kept as video or as MP3 audio.
/// MP3 arrives with the Format / Quality preset ticket.
public enum Format: String, Codable, Sendable, CaseIterable {
    case video
}

/// A fixed video quality choice. 1080p / 720p arrive with the Format / Quality preset ticket.
public enum QualityPreset: String, Codable, Sendable, CaseIterable {
    case best
}

/// The rule that turns a video's details into its file name and folder.
/// Channel - Title, Date - Title and Custom arrive with the Naming pattern ticket.
public enum NamingPattern: String, Codable, Sendable, CaseIterable {
    case title
}

/// The choices a Queue item is downloaded with. Each item keeps its own copy so Retry reuses them.
public struct DownloadOptions: Equatable, Codable, Sendable {
    public var format: Format
    public var quality: QualityPreset
    public var naming: NamingPattern

    public init(format: Format, quality: QualityPreset, naming: NamingPattern) {
        self.format = format
        self.quality = quality
        self.naming = naming
    }

    /// First-run defaults: Video, Best, Title.
    public static let `default` = DownloadOptions(format: .video, quality: .best, naming: .title)
}

/// Everything needed to download one video.
public struct DownloadRequest: Equatable, Sendable {
    /// A single video link.
    public var url: String
    public var downloadFolder: URL
    public var options: DownloadOptions
    /// The Source the video came from (channel name, playlist title and index), for naming.
    public var origin: VideoOrigin

    public init(url: String, downloadFolder: URL, options: DownloadOptions, origin: VideoOrigin = .link) {
        self.url = url
        self.downloadFolder = downloadFolder
        self.options = options
        self.origin = origin
    }
}

/// Builds the yt-dlp argv for one `DownloadRequest`.
///
/// The mandatory flags (`--ignore-config` etc.) are not included: `YtDlpRunner` always prepends
/// them via `YtDlpCommand`, so no caller can forget them.
public enum DownloadArguments {
    public static func arguments(for request: DownloadRequest) -> [String] {
        machineOutput
            + ["--no-playlist"]
            + formatSelection(request.options)
            + ["-P", request.downloadFolder.path, "-o", outputTemplate(request.options.naming)]
            + ["--", request.url]
    }

    /// Progress and metadata come only from these lines (see `YtDlpOutputTemplates`).
    /// `--print` implies `--quiet`, which hides progress unless `--progress` is given.
    static let machineOutput = [
        "--newline", "--progress",
        "--progress-template", YtDlpOutputTemplates.progress,
        "--print", YtDlpOutputTemplates.video,
        "--print", YtDlpOutputTemplates.file,
    ]

    static func formatSelection(_ options: DownloadOptions) -> [String] {
        switch (options.format, options.quality) {
        case (.video, .best):
            ["-f", "bv*+ba/b", "--merge-output-format", "mp4"]
        }
    }

    static func outputTemplate(_ naming: NamingPattern) -> String {
        switch naming {
        case .title: "%(title)s.%(ext)s"
        }
    }
}
