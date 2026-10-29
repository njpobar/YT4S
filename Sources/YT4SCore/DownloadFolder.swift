import Foundation

/// A video as saved in one Format: what makes a file in the Download folder Already downloaded.
public struct SavedVideo: Hashable, Sendable {
    public var videoID: String
    public var format: Format

    public init(videoID: String, format: Format) {
        self.videoID = videoID
        self.format = format
    }
}

/// The Download folder as naming and skip detection see it: where yt-dlp downloads to, which
/// video each saved file is, and where a finished download is placed.
///
/// yt-dlp never names the final file. It downloads into `incompleteFolder` as `<id>.<ext>`; once
/// the video is looked up YT4S predicts the final name (`plannedFile`), and when the download
/// finishes it moves the file there (`place`), applying the collision rule against the folder as
/// it is at that moment. Each placed file is tagged with its video ID and Format in extended
/// attributes. The folder is the only record of what was downloaded (no ledger, no sidecars):
/// `savedFiles` finds them again wherever they were moved or renamed to inside it.
public struct DownloadFolder: Equatable, Sendable {
    public let url: URL

    /// Extended attribute holding the YouTube video ID of a file YT4S saved.
    public static let videoIDAttribute = "com.yt4s.videoid"
    /// Extended attribute holding the `Format` raw value (`video` / `mp3`) of a file YT4S saved.
    public static let formatAttribute = "com.yt4s.format"
    /// Hidden folder inside the Download folder holding downloads in progress (same volume, so
    /// placing is a rename). Partial files left by a cancelled download resume on retry.
    public static let incompleteFolderName = ".yt4s-incomplete"

    /// Where a finished download ended up.
    public enum Placement: Equatable, Sendable {
        /// Moved to this new file.
        case placed(URL)
        /// Not placed: this file already holds the same video in the same Format.
        case alreadyThere(URL)
    }

    public init(url: URL) {
        self.url = url
    }

    public var incompleteFolder: URL {
        url.appendingPathComponent(Self.incompleteFolderName, isDirectory: true)
    }

    /// The video and Format YT4S tagged a file with, or `nil` (no file, or not saved by YT4S).
    public func savedVideo(ofFileAt file: URL) -> SavedVideo? {
        guard let id = Self.attribute(Self.videoIDAttribute, of: file), !id.isEmpty,
              let format = Self.attribute(Self.formatAttribute, of: file).flatMap(Format.init(rawValue:))
        else { return nil }
        return SavedVideo(videoID: id, format: format)
    }

    /// Every file YT4S saved anywhere inside the folder (subfolders too, under any name), by
    /// video and Format. Downloads in progress do not count. Empty when the folder is missing.
    public func savedFiles() -> [SavedVideo: URL] {
        // Relative paths, so the URLs are spelled like `url` (not resolved through /private).
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return [:] }
        var saved: [SavedVideo: URL] = [:]
        for case let relativePath as String in enumerator {
            if relativePath == Self.incompleteFolderName {
                enumerator.skipDescendants()
                continue
            }
            guard enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            let file = url.appendingPathComponent(relativePath)
            guard let video = savedVideo(ofFileAt: file) else { continue }
            saved[video] = saved[video] ?? file
        }
        return saved
    }

    /// What is at `relativePath` now, as far as `video` is concerned.
    public func occupant(of relativePath: String, for video: SavedVideo) -> FileOccupant {
        let file = url.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: file.path) else { return .free }
        return savedVideo(ofFileAt: file) == video ? .sameVideo : .otherVideo
    }

    /// The file a video would be saved as right now (or the file already holding it, unless
    /// `downloadAgain`).
    public func plannedFile(_ plan: NamePlan, video: SavedVideo, fileExtension: String, downloadAgain: Bool = false) -> URL {
        url.appendingPathComponent(plan.resolvedPath(videoID: video.videoID, fileExtension: fileExtension, downloadAgain: downloadAgain) {
            occupant(of: $0, for: video)
        })
    }

    /// Moves a finished download to its final name (the extension is the downloaded file's) and
    /// tags it with `video`. Never replaces a file: when the same video in the same Format already
    /// has that name the download is left where it is and `.alreadyThere` says which file holds it,
    /// unless `downloadAgain`, which always makes a new file under the collision rule.
    public func place(_ downloaded: URL, plan: NamePlan, video: SavedVideo, downloadAgain: Bool = false) throws -> Placement {
        let fileManager = FileManager.default
        let destination = plannedFile(plan, video: video, fileExtension: downloaded.pathExtension, downloadAgain: downloadAgain)
        if fileManager.fileExists(atPath: destination.path) {
            return .alreadyThere(destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Fails rather than replaces if a file appeared there meanwhile.
        try fileManager.moveItem(at: downloaded, to: destination)
        for (name, value) in [(Self.videoIDAttribute, video.videoID), (Self.formatAttribute, video.format.rawValue)] {
            let bytes = Array(value.utf8)
            guard setxattr(destination.path, name, bytes, bytes.count, 0, 0) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
        }
        removeIncompleteFolderIfEmpty()
        return .placed(destination)
    }

    /// Deletes a download that will not be placed (failed or cancelled after yt-dlp wrote it).
    /// Only ever touches files inside `incompleteFolder`.
    public func discardIncomplete(_ downloaded: URL) {
        guard downloaded.deletingLastPathComponent().standardizedFileURL == incompleteFolder.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: downloaded)
        removeIncompleteFolderIfEmpty()
    }

    /// Best effort: leave nothing behind once no download is in progress.
    private func removeIncompleteFolderIfEmpty() {
        if (try? FileManager.default.contentsOfDirectory(atPath: incompleteFolder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: incompleteFolder)
        }
    }

    private static func attribute(_ name: String, of file: URL) -> String? {
        let size = getxattr(file.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(file.path, name, &bytes, size, 0, 0) == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
