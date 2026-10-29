import Foundation

/// Whether a download is kept as video or as MP3 audio.
public enum Format: String, Codable, Sendable, CaseIterable {
    case video
    case mp3

    /// What the Format control shows.
    public var label: String {
        switch self {
        case .video: "Video"
        case .mp3: "MP3"
        }
    }

    /// Whether the Quality preset applies; MP3 is always the same fixed high bitrate.
    public var usesQualityPreset: Bool { self == .video }
}

/// A fixed video quality choice. Only used when the Format is Video.
public enum QualityPreset: String, Codable, Sendable, CaseIterable {
    case best
    case p1080 = "1080p"
    case p720 = "720p"

    /// What the Quality preset control shows.
    public var label: String {
        switch self {
        case .best: "Best"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }

    /// The tallest video this preset allows, or `nil` for no cap.
    var maxHeight: Int? {
        switch self {
        case .best: nil
        case .p1080: 1080
        case .p720: 720
        }
    }
}

/// The rule that turns a video's details into its file name and folder (see `NamePlan`).
/// Raw values are persisted by `Settings`: do not rename them.
public enum NamingPattern: String, Codable, Sendable, CaseIterable {
    case title
    case channelTitle = "channel-title"
    case dateTitle = "date-title"

    /// What the Naming pattern control shows.
    public var label: String {
        switch self {
        case .title: "Title"
        case .channelTitle: "Channel - Title"
        case .dateTitle: "Date - Title"
        }
    }
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
            + ["-P", request.downloadFolder.path, "-o", outputTemplate]
            + ["--", request.url]
    }

    /// Progress and metadata come only from these lines (see `YtDlpOutputTemplates`).
    /// `--print` implies `--quiet`, which hides progress unless `--progress` is given.
    static let machineOutput = [
        "--newline", "--progress",
        "--progress-template", YtDlpOutputTemplates.progress,
        "--print", YtDlpOutputTemplates.video,
        "--print", YtDlpOutputTemplates.details,
        "--print", YtDlpOutputTemplates.file,
    ]

    /// The yt-dlp flags for a Format / Quality preset. Never adds subtitles, chapters or SponsorBlock.
    static func formatSelection(_ options: DownloadOptions) -> [String] {
        switch options.format {
        case .video:
            ["-f", videoSelector(maxHeight: options.quality.maxHeight)]
                // QuickTime (and Sarah's M1) play H.264 + AAC; YouTube's top formats are often AV1 / VP9 + Opus.
                // Sorting prefers H.264, then the highest resolution, then AAC, and still takes any codec
                // when no H.264 stream exists. Verified against real yt-dlp: on a 4K video Best picks
                // 1080p avc1 + mp4a, not 2160p AV1.
                + ["-S", "vcodec:h264,res,acodec:aac"]
                + ["--merge-output-format", "mp4"]
        case .mp3:
            ["-f", "ba/b"]
                + ["-x", "--audio-format", "mp3", "--audio-quality", "320K"]
                // MP3 cannot hold WebP cover art.
                + ["--embed-thumbnail", "--convert-thumbnails", "jpg"]
                // --embed-metadata embeds chapters too unless told not to.
                + ["--embed-metadata", "--no-embed-chapters"]
        }
    }

    /// Best streams at or below `maxHeight`; only if none exist, the best above it.
    private static func videoSelector(maxHeight: Int?) -> String {
        guard let maxHeight else { return "bv*+ba/b" }
        return "bv*[height<=\(maxHeight)]+ba/b[height<=\(maxHeight)]/bv*+ba/b"
    }

    /// yt-dlp never picks the final name: it downloads to `<id>.<ext>` in the hidden incomplete
    /// folder and the Queue moves the file to its Naming pattern name (see `DownloadFolder`).
    static let outputTemplate = "\(DownloadFolder.incompleteFolderName)/%(id)s.%(ext)s"
}
