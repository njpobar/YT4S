import Foundation

/// What naming needs to know about one video once yt-dlp has looked it up.
public struct VideoDetails: Equatable, Sendable {
    public var id: String
    public var title: String
    /// The video's own channel.
    public var channel: String?
    /// Upload date as yt-dlp gives it, `YYYYMMDD`.
    public var uploadDate: String?

    public init(id: String, title: String, channel: String? = nil, uploadDate: String? = nil) {
        self.id = id
        self.title = title
        self.channel = channel
        self.uploadDate = uploadDate
    }
}

/// A file's place in the Download folder before cleanup: folders, an optional playlist index
/// prefix, and the name stem. Presets build one from a Naming pattern; a custom pattern can build
/// one from its own rendered text. `relativePath` applies the same cleanup to every part.
public struct NamePlan: Equatable, Sendable {
    /// Folder names inside the Download folder, outermost first, before cleanup.
    public var folders: [String]
    /// Zero-padded playlist index (e.g. `01`), written as `01 - ` before the stem.
    public var indexPrefix: String?
    /// The file name without extension, before cleanup.
    public var stem: String

    public init(folders: [String] = [], indexPrefix: String? = nil, stem: String) {
        self.folders = folders
        self.indexPrefix = indexPrefix
        self.stem = stem
    }

    /// The plan for a preset: `<stem>` for a single link, `<Channel name>/<stem>` for a Channel
    /// source, `<Playlist title>/<NN> - <stem>` for a Playlist source.
    public init(pattern: NamingPattern, video: VideoDetails, origin: VideoOrigin) {
        let lead: String? = switch pattern {
        case .title: nil
        case .channelTitle: video.channel
        case .dateTitle: video.uploadDate.flatMap(Self.isoDate)
        }
        let title = Self.nonEmpty(FileNameCleanup.clean(video.title)) ?? video.id
        let stem = [lead.map(FileNameCleanup.clean).flatMap(Self.nonEmpty), title]
            .compactMap { $0 }
            .joined(separator: " - ")

        switch origin.sourceKind {
        case .video:
            self.init(stem: stem)
        case .channel:
            self.init(folders: [Self.folderName(origin.channelName, fallback: "Untitled channel")], stem: stem)
        case .playlist:
            let width = max(2, String(origin.playlistCount ?? 0).count)
            let prefix = origin.playlistIndex.map { index in
                String(repeating: "0", count: max(0, width - String(index).count)) + String(index)
            }
            self.init(
                folders: [Self.folderName(origin.playlistTitle, fallback: "Untitled playlist")],
                indexPrefix: prefix,
                stem: stem
            )
        }
    }

    /// The path inside the Download folder, e.g. `Playlist/01 - Title.mp4`, with every folder and
    /// the file name cleaned and trimmed under the filesystem limit (the stem gives way; prefix,
    /// suffix and extension are kept). A stem left empty becomes the video ID.
    /// `withIDSuffix` appends ` [<video id>]`: the collision rule's name for a newcomer.
    public func relativePath(videoID: String, fileExtension: String, withIDSuffix: Bool) -> String {
        let folderPath = folders
            .compactMap { Self.nonEmpty(FileNameCleanup.trim(FileNameCleanup.clean($0), toBytes: FileNameCleanup.maxNameBytes)) }
            .map { "\($0)/" }
            .joined()
        let prefix = indexPrefix.map { "\($0) - " } ?? ""
        let suffix = (withIDSuffix ? " [\(videoID)]" : "") + ".\(fileExtension)"
        let budget = FileNameCleanup.maxNameBytes - FileNameCleanup.byteCount(prefix + suffix)
        let stem = FileNameCleanup.trim(Self.nonEmpty(FileNameCleanup.clean(stem)) ?? videoID, toBytes: budget)
        return folderPath + prefix + stem + suffix
    }

    private static func folderName(_ name: String?, fallback: String) -> String {
        nonEmpty(FileNameCleanup.clean(name ?? "")) ?? fallback
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    /// `20091025` -> `2009-10-25`; `nil` for anything else (yt-dlp prints `NA` when unknown).
    private static func isoDate(_ yyyymmdd: String) -> String? {
        guard yyyymmdd.count == 8, yyyymmdd.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let digits = Array(yyyymmdd)
        return "\(String(digits[0..<4]))-\(String(digits[4..<6]))-\(String(digits[6..<8]))"
    }
}
