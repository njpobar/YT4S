import Foundation
import Testing
@testable import YT4SCore

/// Skip detection on a temp Download folder: a file counts as Already downloaded by its
/// (video ID, Format) extended attributes, wherever it is and whatever it is called.
@Suite struct SkipDetectionTests {
    let root: URL
    let folder: DownloadFolder
    let rick = SavedVideo(videoID: "dQw4w9WgXcQ", format: .video)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folder = DownloadFolder(url: root)
    }

    /// Saves a finished download the way the Queue does.
    @discardableResult
    func save(_ video: SavedVideo, plan: NamePlan = NamePlan(stem: "Never Gonna Give You Up")) throws -> URL {
        let ext = video.format == .mp3 ? "mp3" : "mp4"
        try FileManager.default.createDirectory(at: folder.incompleteFolder, withIntermediateDirectories: true)
        let file = folder.incompleteFolder.appendingPathComponent("\(video.videoID).\(ext)")
        try "media".write(to: file, atomically: true, encoding: .utf8)
        guard case .placed(let placed) = try folder.place(file, plan: plan, video: video) else {
            throw CocoaError(.fileWriteFileExists)
        }
        return placed
    }

    func attribute(_ name: String, of file: URL) -> String? {
        let size = getxattr(file.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        _ = getxattr(file.path, name, &bytes, size, 0, 0)
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func aSavedFileIsTaggedWithItsVideoIDAndFormat() throws {
        let file = try save(SavedVideo(videoID: "dQw4w9WgXcQ", format: .mp3))

        #expect(attribute("com.yt4s.videoid", of: file) == "dQw4w9WgXcQ")
        #expect(attribute("com.yt4s.format", of: file) == "mp3")
    }

    @Test func theSameVideoInTheSameFormatMatches() throws {
        let file = try save(rick)

        #expect(folder.savedFiles() == [rick: file])
    }

    @Test func theSameVideoInTheOtherFormatDoesNotMatch() throws {
        try save(SavedVideo(videoID: "dQw4w9WgXcQ", format: .mp3))

        #expect(folder.savedFiles()[rick] == nil)
    }

    @Test func aRenamedFileMovedIntoASubfolderStillMatches() throws {
        let file = try save(rick)
        let renamed = root.appendingPathComponent("Favourites/Old/Rick.mp4")
        try FileManager.default.createDirectory(at: renamed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: renamed)

        #expect(folder.savedFiles()[rick]?.standardizedFileURL == renamed.standardizedFileURL)
    }

    @Test func aFileWithoutTheAttributesDoesNotMatch() throws {
        try "mine".write(to: root.appendingPathComponent("Never Gonna Give You Up.mp4"), atomically: true, encoding: .utf8)
        let file = try save(rick)
        removexattr(file.path, "com.yt4s.format", 0)

        #expect(folder.savedFiles().isEmpty)
    }

    @Test func aMovedOutOrDeletedFileNoLongerMatches() throws {
        let file = try save(rick)
        try FileManager.default.removeItem(at: file)

        #expect(folder.savedFiles().isEmpty)
    }

    @Test func downloadsInProgressDoNotCount() throws {
        try FileManager.default.createDirectory(at: folder.incompleteFolder, withIntermediateDirectories: true)
        let inProgress = folder.incompleteFolder.appendingPathComponent("dQw4w9WgXcQ.mp4")
        try "media".write(to: inProgress, atomically: true, encoding: .utf8)
        for (name, value) in [("com.yt4s.videoid", "dQw4w9WgXcQ"), ("com.yt4s.format", "video")] {
            let bytes = Array(value.utf8)
            setxattr(inProgress.path, name, bytes, bytes.count, 0, 0)
        }

        #expect(folder.savedFiles().isEmpty)
    }

    @Test func aMissingDownloadFolderHasNothingSaved() {
        #expect(DownloadFolder(url: root.appendingPathComponent("nope")).savedFiles().isEmpty)
    }
}
