import Foundation
import Testing
@testable import YT4SCore

/// Naming against the real bundled yt-dlp and YouTube: paste a video, a playlist and a channel,
/// download, and check where the files land. Needs network, so it only runs when
/// `YT4S_REAL_TOOLS` names a folder with `yt-dlp/yt-dlp_macos`, `ffmpeg`, `ffprobe` and `deno`
/// (the app's `Contents/Resources/bin` layout), e.g. a built YT4S.app's.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["YT4S_REAL_TOOLS"] != nil), .serialized)
struct RealYtDlpNamingTests {
    static var tools: BundledTools? {
        guard let bin = ProcessInfo.processInfo.environment["YT4S_REAL_TOOLS"] else { return nil }
        let folder = URL(fileURLWithPath: bin, isDirectory: true)
        return BundledTools(
            ytDlp: folder.appendingPathComponent("yt-dlp/yt-dlp_macos"),
            ffmpegDirectory: folder,
            deno: folder.appendingPathComponent("deno")
        )
    }

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

    @Test func aSingleVideoDatedAndTheSameTitleAgainFromAChannelFolder() async throws {
        let (folder, items) = try await download(
            "https://www.youtube.com/watch?v=jNQXAC9IVRw\nhttps://www.youtube.com/@jawed",
            DownloadOptions(format: .video, quality: .p720, naming: .dateTitle)
        )

        #expect(items.allSatisfy { $0.isFinished })
        #expect(files(in: folder) == ["2005-04-24 - Me at the zoo.mp4", "jawed/2005-04-24 - Me at the zoo.mp4"])
        #expect(DownloadFolder(url: folder).videoID(ofFileAt: folder.appendingPathComponent("jawed/2005-04-24 - Me at the zoo.mp4")) == "jNQXAC9IVRw")
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
}
