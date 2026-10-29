import Foundation

/// The Download folder as naming sees it: where yt-dlp downloads to, which video each saved file
/// is, and where a finished download is placed.
///
/// yt-dlp never names the final file. It downloads into `incompleteFolder` as `<id>.<ext>`; once
/// the video is looked up YT4S predicts the final name (`plannedFile`), and when the download
/// finishes it moves the file there (`place`), applying the collision rule against the folder as
/// it is at that moment. Each placed file is tagged with its video ID in an extended attribute,
/// which is how the collision rule (and Already downloaded) tell videos apart.
public struct DownloadFolder: Equatable, Sendable {
    public let url: URL

    /// Extended attribute holding the YouTube video ID of a file YT4S saved.
    public static let videoIDAttribute = "com.yt4s.video-id"
    /// Hidden folder inside the Download folder holding downloads in progress (same volume, so
    /// placing is a rename). Partial files left by a cancelled download resume on retry.
    public static let incompleteFolderName = ".yt4s-incomplete"

    public init(url: URL) {
        self.url = url
    }

    public var incompleteFolder: URL {
        url.appendingPathComponent(Self.incompleteFolderName, isDirectory: true)
    }

    /// The video ID YT4S tagged a file with, or `nil` (no file, or not saved by YT4S).
    public func videoID(ofFileAt file: URL) -> String? {
        let size = getxattr(file.path, Self.videoIDAttribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(file.path, Self.videoIDAttribute, &bytes, size, 0, 0) == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// What is at `relativePath` now, as far as `videoID` is concerned.
    public func occupant(of relativePath: String, for videoID: String) -> FileOccupant {
        let file = url.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: file.path) else { return .free }
        return self.videoID(ofFileAt: file) == videoID ? .sameVideo : .otherVideo
    }

    /// The file a video would be saved as right now.
    public func plannedFile(_ plan: NamePlan, videoID: String, fileExtension: String) -> URL {
        url.appendingPathComponent(plan.resolvedPath(videoID: videoID, fileExtension: fileExtension) {
            occupant(of: $0, for: videoID)
        })
    }

    /// Moves a finished download to its final name (the extension is the downloaded file's),
    /// replacing only a file of the same video, and tags it with `videoID`.
    @discardableResult
    public func place(_ downloaded: URL, plan: NamePlan, videoID: String) throws -> URL {
        let fileManager = FileManager.default
        let destination = plannedFile(plan, videoID: videoID, fileExtension: downloaded.pathExtension)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: downloaded, to: destination)
        let id = Array(videoID.utf8)
        guard setxattr(destination.path, Self.videoIDAttribute, id, id.count, 0, 0) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        removeIncompleteFolderIfEmpty()
        return destination
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
}
