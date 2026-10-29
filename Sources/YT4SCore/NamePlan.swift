import Foundation

/// What is at a path in the Download folder, for the collision rule.
public enum FileOccupant: Equatable, Sendable {
    case free
    /// A file YT4S saved for the same video (Download again replaces it).
    case sameVideo
    /// Any other file: another video, or a file YT4S did not save.
    case otherVideo
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
    /// A custom pattern ignores the Source: its rendered text is the whole path stem.
    public init(pattern: NamingPattern, video: VideoDetails, origin: VideoOrigin) {
        if pattern == .custom {
            self.init(customName: video.customName ?? video.title)
            return
        }
        let lead: String? = switch pattern {
        case .title, .custom: nil
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

    /// The collision rule: the plain name, unless a different video already has it; then the
    /// newcomer gets ` [<video id>]`. `occupant` says what is at a relative path now.
    public func resolvedPath(videoID: String, fileExtension: String, occupant: (String) -> FileOccupant) -> String {
        let plain = relativePath(videoID: videoID, fileExtension: fileExtension, withIDSuffix: false)
        guard occupant(plain) == .otherVideo else { return plain }
        // The suffixed name carries this video's ID, so whatever is there is taken to be this video.
        return relativePath(videoID: videoID, fileExtension: fileExtension, withIDSuffix: true)
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

extension NamingPattern {
    /// The "e.g." file name shown next to the Naming pattern control.
    public func example(format: Format) -> String {
        let sample = VideoDetails(id: "dQw4w9WgXcQ", title: "My Video", channel: "Some Channel", uploadDate: "20261012")
        let request = DownloadRequest(
            url: "", downloadFolder: URL(fileURLWithPath: "/"),
            options: DownloadOptions(format: format, quality: .best, naming: self)
        )
        return request.namePlan(for: sample)
            .relativePath(videoID: sample.id, fileExtension: request.expectedFileExtension, withIDSuffix: false)
    }
}

extension DownloadRequest {
    /// Where this request's video goes under its Naming pattern, once yt-dlp has looked it up.
    public func namePlan(for video: VideoDetails) -> NamePlan {
        NamePlan(pattern: options.naming, video: video, origin: origin)
    }

    /// The extension the finished file is expected to have, for predicting its name.
    public var expectedFileExtension: String {
        switch options.format {
        case .video: "mp4"
        case .mp3: "mp3"
        }
    }
}
