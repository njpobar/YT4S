import Foundation
import Testing
@testable import YT4SCore

/// Naming against the real bundled yt-dlp and YouTube: paste a video, a playlist and a channel,
/// download, and check where the files land. Live (see `LiveTests`), ~2 min.
@MainActor @Suite(.live, .serialized)
struct LiveNamingTests {
    static var tools: BundledTools? { LiveTests.tools }

    private func download(_ links: String, _ options: DownloadOptions) async throws -> (URL, [QueueItem]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-real-\(UUID().uuidString)", isDirectory: true)
        let model = MainWindowModel(queue: Queue(runner: YtDlpRunner(tools: try #require(Self.tools))), downloadFolder: folder)
        model.options = options
        model.pasteText = links
        model.download()
        await model.waitUntilListed()
        await model.queue.waitUntilIdle()
        #expect(model.errorMessage == nil)
        return (folder, model.queue.items)
    }

    private func files(in folder: URL) -> [String] {
        (FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? [])
            .filter { path in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory)
                return !isDirectory.boolValue
            }
            .sorted()
    }

    @Test func aSingleVideoDatedThenTheSameVideoFromItsChannelIsAlreadyDownloaded() async throws {
        let (folder, items) = try await download(
            "https://www.youtube.com/watch?v=jNQXAC9IVRw\nhttps://www.youtube.com/@jawed",
            DownloadOptions(format: .video, quality: .p720, naming: .dateTitle)
        )

        // The channel's only video is the one just downloaded: Already downloaded, not fetched twice.
        let saved = folder.appendingPathComponent("2005-04-24 - Me at the zoo.mp4")
        #expect(items.map(\.state) == [.finished(file: saved), .alreadyDownloaded(file: saved)])
        #expect(files(in: folder) == ["2005-04-24 - Me at the zoo.mp4"])
        #expect(DownloadFolder(url: folder).savedVideo(ofFileAt: saved) == SavedVideo(videoID: "jNQXAC9IVRw", format: .video))
    }

    @Test func aPlaylistAsMP3WithChannelTitle() async throws {
        let (folder, items) = try await download(
            "https://www.youtube.com/playlist?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu",
            DownloadOptions(format: .mp3, quality: .best, naming: .channelTitle)
        )

        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.isFinished })
        #expect(files(in: folder) == [
            "Rick Astley Live at The O2/01 - Rick Astley - Rick Astley - Angels On My Side (Live at The O2, London, April 2026).mp3",
            "Rick Astley Live at The O2/02 - Rick Astley - Rick Astley - Dance (Live at The O2, London, April 2026).mp3",
            "Rick Astley Live at The O2/03 - Rick Astley - Rick Astley - Keep Singing (Live at The O2, London, April 2026).mp3",
        ])
    }

    @Test func aSecondVideoWithTheSameNameGetsItsID() async throws {
        let (folder, _) = try await download(
            "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            DownloadOptions(format: .mp3, quality: .best, naming: .title)
        )
        // Someone else's file under the same name: the next download must not replace it.
        let existing = folder.appendingPathComponent("Me at the zoo.mp3")
        try FileManager.default.removeItem(at: existing)
        try "not this video".write(to: existing, atomically: true, encoding: .utf8)

        let model = MainWindowModel(queue: Queue(runner: YtDlpRunner(tools: try #require(Self.tools))), downloadFolder: folder)
        model.options = DownloadOptions(format: .mp3, quality: .best, naming: .title)
        model.pasteText = "https://youtu.be/jNQXAC9IVRw"
        model.download()
        await model.queue.waitUntilIdle()

        #expect(files(in: folder) == ["Me at the zoo [jNQXAC9IVRw].mp3", "Me at the zoo.mp3"])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "not this video")
    }

    @Test func aCustomTemplateWithPlaylistFieldsAndADateFolder() async throws {
        let (folder, items) = try await download(
            "https://www.youtube.com/playlist?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu",
            DownloadOptions(
                format: .mp3, quality: .best, naming: .custom,
                customPattern: "%(playlist_title)s/%(upload_date>%Y)s/%(playlist_index)03d of %(playlist_count)s: %(id)s.%(ext)s"
            )
        )

        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.isFinished })
        let names = files(in: folder)
        #expect(names.count == 3)
        #expect(names.allSatisfy { $0.hasPrefix("Rick Astley Live at The O2/20") && $0.hasSuffix(".mp3") })
        #expect(names.map { ($0 as NSString).lastPathComponent.prefix(11) } == ["001 of 3 - ", "002 of 3 - ", "003 of 3 - "])
    }

    @Test func aRenamedVideoIsAlreadyDownloadedAndDownloadAgainSavesASecondCopy() async throws {
        let options = DownloadOptions(format: .mp3, quality: .best, naming: .title)
        let (folder, _) = try await download("https://www.youtube.com/watch?v=jNQXAC9IVRw", options)
        let renamed = folder.appendingPathComponent("zoo.mp3")
        try FileManager.default.moveItem(at: folder.appendingPathComponent("Me at the zoo.mp3"), to: renamed)

        let model = MainWindowModel(queue: Queue(runner: YtDlpRunner(tools: try #require(Self.tools))), downloadFolder: folder)
        model.options = DownloadOptions(format: .mp3, quality: .best, naming: .dateTitle)
        model.pasteText = "https://youtu.be/jNQXAC9IVRw"
        model.download()
        await model.queue.waitUntilIdle()
        #expect(model.queue.items.map(\.state) == [.alreadyDownloaded(file: renamed)])

        model.queue.downloadAgain(model.queue.items[0].id)
        await model.queue.waitUntilIdle()

        let copy = folder.appendingPathComponent("2005-04-24 - Me at the zoo.mp3")
        #expect(model.queue.items.map(\.state) == [.finished(file: copy)])
        #expect(files(in: folder) == ["2005-04-24 - Me at the zoo.mp3", "zoo.mp3"])
        #expect(DownloadFolder(url: folder).savedVideo(ofFileAt: copy) == SavedVideo(videoID: "jNQXAC9IVRw", format: .mp3))
    }
}
