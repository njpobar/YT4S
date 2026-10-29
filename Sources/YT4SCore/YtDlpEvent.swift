import Foundation

/// The `--progress-template` / `--print` templates YT4S passes to yt-dlp.
///
/// YT4S never reads yt-dlp's normal human output. Every fact it needs comes from one of these
/// lines on stdout: a fixed `YT4S-<KIND>` prefix, then tab-separated fields. Free text (titles,
/// paths) uses the `j` conversion so it arrives JSON-encoded and can never contain a raw tab.
/// Missing values print as `NA`.
///
/// To add a new kind of line: add its template here, a case to `YtDlpEvent`, and a parser branch.
public enum YtDlpOutputTemplates {
    /// `--print before_dl:` once per video, after format selection.
    /// Fields: id, format_id (`395+251` when merging), per-part sizes (JSON array, empty for a
    /// single format), total size, title (JSON).
    public static let video =
        "before_dl:YT4S-VIDEO\t%(id)s\t%(format_id)s\t%(requested_formats.:.filesize,filesize_approx)j\t%(filesize,filesize_approx)s\t%(title)j"

    /// `--progress-template download:` once per progress tick of each downloaded part.
    public static let progress =
        "download:YT4S-PROGRESS\t%(info.id)s\t%(info.format_id)s\t%(progress.status)s\t%(progress.downloaded_bytes)s\t%(progress.total_bytes)s\t%(progress.total_bytes_estimate)s\t%(progress.speed)s\t%(progress.eta)s\t%(progress.fragment_index)s\t%(progress.fragment_count)s"

    /// `--print after_move:` once per video, with the final file path (JSON).
    public static let file = "after_move:YT4S-FILE\t%(id)s\t%(filepath)j"
}

/// What yt-dlp reported for one video once its formats were picked.
public struct VideoInfo: Equatable, Sendable {
    public var id: String
    public var title: String
    /// One entry per downloaded part, in download order (video then audio when merging).
    public var formatIDs: [String]
    /// Size of each part, aligned with `formatIDs`; `nil` when yt-dlp does not know it.
    public var partSizes: [Int64?]

    public init(id: String, title: String, formatIDs: [String], partSizes: [Int64?]) {
        self.id = id
        self.title = title
        self.formatIDs = formatIDs
        self.partSizes = partSizes
    }
}

/// One progress tick for one downloaded part (yt-dlp's progress hook dict).
public struct PartProgress: Equatable, Sendable {
    public enum Status: String, Sendable {
        case downloading, finished, error
    }

    public var videoID: String
    public var formatID: String
    public var status: Status
    public var downloadedBytes: Int64?
    public var totalBytes: Int64?
    public var totalBytesEstimate: Int64?
    /// Bytes per second.
    public var speed: Double?
    /// Seconds left for this part.
    public var eta: Int?
    public var fragmentIndex: Int?
    public var fragmentCount: Int?

    public init(
        videoID: String,
        formatID: String,
        status: Status,
        downloadedBytes: Int64?,
        totalBytes: Int64?,
        totalBytesEstimate: Int64?,
        speed: Double?,
        eta: Int?,
        fragmentIndex: Int?,
        fragmentCount: Int?
    ) {
        self.videoID = videoID
        self.formatID = formatID
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.totalBytesEstimate = totalBytesEstimate
        self.speed = speed
        self.eta = eta
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
    }
}

/// One machine-readable line from yt-dlp's stdout.
public enum YtDlpEvent: Equatable, Sendable {
    case video(VideoInfo)
    case progress(PartProgress)
    case file(videoID: String, path: String)

    /// Parses a stdout line; `nil` for anything that is not one of YT4S's own lines.
    public init?(line: String) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let kind = fields.first else { return nil }
        switch kind {
        case "YT4S-VIDEO":
            guard fields.count == 6, let title = Self.jsonString(fields[5]) else { return nil }
            let formatIDs = fields[2].split(separator: "+").map(String.init)
            let requested = Self.jsonSizes(fields[3]) ?? []
            let partSizes: [Int64?] = requested.count == formatIDs.count
                ? requested
                : formatIDs.count == 1 ? [Self.int(fields[4])] : Array(repeating: nil, count: formatIDs.count)
            self = .video(VideoInfo(id: fields[1], title: title, formatIDs: formatIDs, partSizes: partSizes))
        case "YT4S-PROGRESS":
            guard fields.count == 11, let status = PartProgress.Status(rawValue: fields[3]) else { return nil }
            self = .progress(PartProgress(
                videoID: fields[1],
                formatID: fields[2],
                status: status,
                downloadedBytes: Self.int(fields[4]),
                totalBytes: Self.int(fields[5]),
                totalBytesEstimate: Self.int(fields[6]),
                speed: Double(fields[7]),
                eta: Self.int(fields[8]).map(Int.init),
                fragmentIndex: Self.int(fields[9]).map(Int.init),
                fragmentCount: Self.int(fields[10]).map(Int.init)
            ))
        case "YT4S-FILE":
            guard fields.count == 3, let path = Self.jsonString(fields[2]) else { return nil }
            self = .file(videoID: fields[1], path: path)
        default:
            return nil
        }
    }

    /// yt-dlp prints numbers as ints or floats (`4272.0`), and `NA` when missing.
    private static func int(_ field: String) -> Int64? {
        if let value = Int64(field) { return value }
        guard let value = Double(field), value.isFinite else { return nil }
        return Int64(value.rounded())
    }

    private static func jsonString(_ field: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(field.utf8))
    }

    private static func jsonSizes(_ field: String) -> [Int64?]? {
        guard let values = try? JSONDecoder().decode([Double?].self, from: Data(field.utf8)) else { return nil }
        return values.map { $0.map { Int64($0.rounded()) } }
    }
}
