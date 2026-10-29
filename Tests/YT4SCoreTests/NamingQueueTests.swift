import Foundation
import Testing
@testable import YT4SCore

/// Naming end to end: the real Queue and runner against the fake yt-dlp, which looks every video
/// up as "Fake Video <id>" by "Fake Channel", uploaded 2009-10-25.
@MainActor @Suite struct NamingQueueTests {
    private func download(
        _ fake: FakeYtDlp,
        id: String = "abc123",
        naming: NamingPattern = .title,
        customTemplate: String = "",
        format: Format = .video,
        origin: VideoOrigin = .link
    ) async -> QueueItem {
        let queue = Queue(runner: fake.runner(scenario: "success"))
        queue.add(DownloadRequest(
            url: "https://www.youtube.com/watch?v=\(id)",
            downloadFolder: fake.downloadFolder,
            options: DownloadOptions(format: format, quality: .best, naming: naming, customTemplate: customTemplate),
            origin: origin
        ))
        await queue.waitUntilIdle()
        return queue.items[0]
    }

    private func savedFiles(_ fake: FakeYtDlp) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: fake.downloadFolder.path)
        return (enumerator?.allObjects as? [String] ?? [])
            .filter { !$0.hasPrefix(".") }
            .filter { path in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: fake.downloadFolder.appendingPathComponent(path).path, isDirectory: &isDirectory)
                return !isDirectory.boolValue
            }
            .sorted()
    }

    @Test(arguments: [
        (NamingPattern.title, "Fake Video abc123.mp4"),
        (.channelTitle, "Fake Channel - Fake Video abc123.mp4"),
        (.dateTitle, "2009-10-25 - Fake Video abc123.mp4"),
    ])
    func aSingleLinkLandsFlatNamedByThePreset(naming: NamingPattern, file: String) async throws {
        let fake = try FakeYtDlp()

        let item = await download(fake, naming: naming)

        #expect(item.state == .finished(file: fake.downloadFolder.appendingPathComponent(file)))
        #expect(savedFiles(fake) == [file])
    }

    @Test func nothingIsLeftInTheIncompleteFolder() async throws {
        let fake = try FakeYtDlp()

        _ = await download(fake)

        let incomplete = DownloadFolder(url: fake.downloadFolder).incompleteFolder
        #expect(!FileManager.default.fileExists(atPath: incomplete.path))
    }

    @Test func aChannelSourceVideoGoesInTheChannelFolder() async throws {
        let fake = try FakeYtDlp()
        let origin = VideoOrigin(sourceKind: .channel, videoID: "abc123", channelName: "jawed", playlistIndex: 1, playlistCount: 1)

        _ = await download(fake, origin: origin)

        #expect(savedFiles(fake) == ["jawed/Fake Video abc123.mp4"])
    }

    @Test func aPlaylistSourceVideoGoesInThePlaylistFolderWithItsIndex() async throws {
        let fake = try FakeYtDlp()
        let origin = VideoOrigin(
            sourceKind: .playlist, videoID: "abc123", channelName: "Owner",
            playlistTitle: "Zoo: Trips", playlistIndex: 2, playlistCount: 3
        )

        _ = await download(fake, format: .mp3, origin: origin)

        #expect(savedFiles(fake) == ["Zoo - Trips/02 - Fake Video abc123.mp3"])
    }

    @Test func aDifferentFileWithTheSameNameIsKeptAndTheNewcomerGetsItsID() async throws {
        let fake = try FakeYtDlp()
        try "someone else".write(to: fake.downloadFolder.appendingPathComponent("Fake Video abc123.mp4"), atomically: true, encoding: .utf8)

        let item = await download(fake)

        #expect(item.state == .finished(file: fake.downloadFolder.appendingPathComponent("Fake Video abc123 [abc123].mp4")))
        #expect(savedFiles(fake) == ["Fake Video abc123 [abc123].mp4", "Fake Video abc123.mp4"])
    }

    @Test func theSavedFileRemembersItsVideo() async throws {
        let fake = try FakeYtDlp()

        let item = await download(fake)

        guard case .finished(let file) = item.state else { Issue.record("not finished"); return }
        #expect(DownloadFolder(url: fake.downloadFolder).videoID(ofFileAt: file) == "abc123")
    }

    @Test func theFinalNameIsPredictedBeforeTheDownloadStarts() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "slow", extraEnvironment: ["YT4S_FAKE_STEP_DELAY": "0.3"]))
        queue.add(DownloadRequest(
            url: "https://www.youtube.com/watch?v=abc123",
            downloadFolder: fake.downloadFolder,
            options: DownloadOptions(format: .video, quality: .best, naming: .dateTitle)
        ))

        let deadline = ContinuousClock.now + .seconds(5)
        while queue.items[0].plannedFile == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let planned = fake.downloadFolder.appendingPathComponent("2009-10-25 - Fake Video abc123.mp4")
        #expect(queue.items[0].plannedFile == planned)
        #expect(!queue.items[0].isFinished)
        #expect(!FileManager.default.fileExists(atPath: planned.path))
        await queue.waitUntilIdle()
        #expect(queue.items[0].state == .finished(file: planned))
    }

    @Test func aCustomTemplateNamesTheFoldersAndFileAndTheAppForcesTheExtension() async throws {
        let fake = try FakeYtDlp()

        let item = await download(fake, naming: .custom, customTemplate: "%(channel)s/%(upload_date)s/%(title)s.%(ext)s", format: .mp3)

        let file = "Fake Channel/20091025/Fake Video abc123.mp3"
        #expect(item.state == .finished(file: fake.downloadFolder.appendingPathComponent(file)))
        #expect(savedFiles(fake) == [file])
    }

    @Test func aCustomTemplateReplacesThePlaylistFolderAndIndexPrefix() async throws {
        let fake = try FakeYtDlp()
        let origin = VideoOrigin(
            sourceKind: .playlist, videoID: "abc123", channelName: "Owner",
            playlistTitle: "Zoo: Trips", playlistIndex: 2, playlistCount: 3
        )

        _ = await download(fake, naming: .custom, customTemplate: "%(title)s", origin: origin)

        #expect(savedFiles(fake) == ["Fake Video abc123.mp4"])
    }

    @Test func aCustomNameGetsTheSameCleanupAndCollisionRule() async throws {
        let fake = try FakeYtDlp()
        try "someone else".write(to: fake.downloadFolder.appendingPathComponent("Fake Video abc123 - x.mp4"), atomically: true, encoding: .utf8)

        let item = await download(fake, naming: .custom, customTemplate: "%(title)s: x")

        let file = "Fake Video abc123 - x [abc123].mp4"
        #expect(item.state == .finished(file: fake.downloadFolder.appendingPathComponent(file)))
    }
}
