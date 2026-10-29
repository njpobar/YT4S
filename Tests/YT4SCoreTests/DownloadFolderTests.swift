import Foundation
import Testing
@testable import YT4SCore

/// Placing a finished download under its predicted name, with the collision rule applied
/// against what is really in the Download folder.
@Suite struct DownloadFolderTests {
    let root: URL
    let folder: DownloadFolder

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folder = DownloadFolder(url: root)
    }

    /// A finished yt-dlp download, where `DownloadArguments` tells yt-dlp to put it.
    func downloaded(_ id: String, ext: String = "mp4", contents: String? = nil) throws -> URL {
        let file = folder.incompleteFolder.appendingPathComponent("\(id).\(ext)")
        try FileManager.default.createDirectory(at: folder.incompleteFolder, withIntermediateDirectories: true)
        try (contents ?? "media \(id)").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @discardableResult
    func placed(_ downloaded: URL, plan: NamePlan, videoID: String, format: Format? = nil, downloadAgain: Bool = false) throws -> URL {
        let video = SavedVideo(videoID: videoID, format: format ?? (downloaded.pathExtension == "mp3" ? .mp3 : .video))
        guard case .placed(let file) = try folder.place(downloaded, plan: plan, video: video, downloadAgain: downloadAgain) else {
            throw CocoaError(.fileWriteFileExists)
        }
        return file
    }

    func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    let rickPlan = NamePlan(folders: ["Rick Astley"], stem: "Never Gonna Give You Up")

    @Test func movesTheDownloadToItsNameCreatingFoldersAndRemovingTheIncompleteFolder() throws {
        let file = try placed(try downloaded("dQw4w9WgXcQ"), plan: rickPlan, videoID: "dQw4w9WgXcQ")

        #expect(file == root.appendingPathComponent("Rick Astley/Never Gonna Give You Up.mp4"))
        #expect(try contents("Rick Astley/Never Gonna Give You Up.mp4") == "media dQw4w9WgXcQ")
        #expect(!FileManager.default.fileExists(atPath: folder.incompleteFolder.path))
        #expect(folder.savedVideo(ofFileAt: file) == SavedVideo(videoID: "dQw4w9WgXcQ", format: .video))
    }

    @Test func predictsTheSameFileBeforeDownloading() throws {
        #expect(folder.plannedFile(rickPlan, video: SavedVideo(videoID: "dQw4w9WgXcQ", format: .video), fileExtension: "mp4")
            == root.appendingPathComponent("Rick Astley/Never Gonna Give You Up.mp4"))
    }

    @Test func aDifferentVideoWithTheSameTitleGetsItsIDAndBothFilesStay() throws {
        try placed(try downloaded("aaaaaaaaaaa"), plan: rickPlan, videoID: "aaaaaaaaaaa")
        #expect(folder.plannedFile(rickPlan, video: SavedVideo(videoID: "bbbbbbbbbbb", format: .video), fileExtension: "mp4")
            == root.appendingPathComponent("Rick Astley/Never Gonna Give You Up [bbbbbbbbbbb].mp4"))

        let second = try placed(try downloaded("bbbbbbbbbbb"), plan: rickPlan, videoID: "bbbbbbbbbbb")

        #expect(second.lastPathComponent == "Never Gonna Give You Up [bbbbbbbbbbb].mp4")
        #expect(try contents("Rick Astley/Never Gonna Give You Up.mp4") == "media aaaaaaaaaaa")
        #expect(try contents("Rick Astley/Never Gonna Give You Up [bbbbbbbbbbb].mp4") == "media bbbbbbbbbbb")
    }

    @Test func aFileYT4SDidNotSaveCountsAsADifferentVideo() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Rick Astley"), withIntermediateDirectories: true)
        try "mine".write(to: root.appendingPathComponent("Rick Astley/Never Gonna Give You Up.mp4"), atomically: true, encoding: .utf8)

        let file = try placed(try downloaded("dQw4w9WgXcQ"), plan: rickPlan, videoID: "dQw4w9WgXcQ")

        #expect(file.lastPathComponent == "Never Gonna Give You Up [dQw4w9WgXcQ].mp4")
        #expect(try contents("Rick Astley/Never Gonna Give You Up.mp4") == "mine")
    }

    @Test func theSameVideoFoundAtItsNameIsAlreadyThereAndNothingIsOverwritten() throws {
        let first = try placed(try downloaded("dQw4w9WgXcQ", contents: "old"), plan: rickPlan, videoID: "dQw4w9WgXcQ")
        let second = try downloaded("dQw4w9WgXcQ", contents: "new")

        let placement = try folder.place(second, plan: rickPlan, video: SavedVideo(videoID: "dQw4w9WgXcQ", format: .video))

        #expect(placement == .alreadyThere(first))
        #expect(try contents("Rick Astley/Never Gonna Give You Up.mp4") == "old")
    }

    @Test func downloadAgainWritesASecondFileUnderTheCollisionRule() throws {
        try placed(try downloaded("dQw4w9WgXcQ", contents: "old"), plan: rickPlan, videoID: "dQw4w9WgXcQ")
        let again = try placed(try downloaded("dQw4w9WgXcQ", contents: "new"), plan: rickPlan, videoID: "dQw4w9WgXcQ", downloadAgain: true)
        let third = try placed(try downloaded("dQw4w9WgXcQ", contents: "newer"), plan: rickPlan, videoID: "dQw4w9WgXcQ", downloadAgain: true)

        #expect(again.lastPathComponent == "Never Gonna Give You Up [dQw4w9WgXcQ].mp4")
        #expect(third.lastPathComponent == "Never Gonna Give You Up [dQw4w9WgXcQ] 2.mp4")
        #expect(try contents("Rick Astley/Never Gonna Give You Up.mp4") == "old")
        #expect(try contents("Rick Astley/Never Gonna Give You Up [dQw4w9WgXcQ].mp4") == "new")
        #expect(try contents("Rick Astley/Never Gonna Give You Up [dQw4w9WgXcQ] 2.mp4") == "newer")
        #expect(folder.savedVideo(ofFileAt: again) == SavedVideo(videoID: "dQw4w9WgXcQ", format: .video))
    }

    @Test func aDownloadThatWillNotBePlacedIsDiscardedButNothingOutsideTheIncompleteFolder() throws {
        let saved = try placed(try downloaded("aaaaaaaaaaa"), plan: rickPlan, videoID: "aaaaaaaaaaa")
        let unplaced = try downloaded("bbbbbbbbbbb")

        folder.discardIncomplete(saved)
        folder.discardIncomplete(unplaced)

        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(!FileManager.default.fileExists(atPath: folder.incompleteFolder.path))
    }

    @Test func videoAndMP3OfOneVideoShareTheFolder() throws {
        try placed(try downloaded("dQw4w9WgXcQ", ext: "mp4"), plan: rickPlan, videoID: "dQw4w9WgXcQ")
        let mp3 = try placed(try downloaded("dQw4w9WgXcQ", ext: "mp3"), plan: rickPlan, videoID: "dQw4w9WgXcQ")

        #expect(mp3 == root.appendingPathComponent("Rick Astley/Never Gonna Give You Up.mp3"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Rick Astley/Never Gonna Give You Up.mp4").path))
    }
}
