import Foundation
import Testing
@testable import YT4SCore

/// Already downloaded end to end: the real Queue and runner against the fake yt-dlp, which looks
/// every video up as "Fake Video <id>".
@MainActor @Suite struct AlreadyDownloadedQueueTests {
    private func request(
        _ fake: FakeYtDlp, id: String = "abc123", format: Format = .video,
        quality: QualityPreset = .best, naming: NamingPattern = .title
    ) -> DownloadRequest {
        DownloadRequest(
            url: "https://www.youtube.com/watch?v=\(id)",
            downloadFolder: fake.downloadFolder,
            options: DownloadOptions(format: format, quality: quality, naming: naming),
            origin: VideoOrigin(sourceKind: .video, videoID: id)
        )
    }

    /// Downloads `requests` in one batch on a fresh Queue.
    private func batch(_ fake: FakeYtDlp, scenario: String = "success", _ requests: [DownloadRequest]) async -> [QueueItem] {
        let queue = Queue(runner: fake.runner(scenario: scenario))
        for request in requests { queue.add(request) }
        await queue.waitUntilIdle()
        return queue.items
    }

    private func file(_ fake: FakeYtDlp, _ relativePath: String) -> URL {
        fake.downloadFolder.appendingPathComponent(relativePath)
    }

    private func savedFiles(_ fake: FakeYtDlp) -> [String] {
        (FileManager.default.enumerator(atPath: fake.downloadFolder.path)?.allObjects as? [String] ?? [])
            .filter { path in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: file(fake, path).path, isDirectory: &isDirectory)
                return !isDirectory.boolValue
            }
            .sorted()
    }

    @Test func aVideoAlreadyInTheFolderIsSkippedWithoutRunningYtDlp() async throws {
        let fake = try FakeYtDlp()
        _ = await batch(fake, [request(fake)])

        // Every run would fail: only a skip can end well.
        let items = await batch(fake, scenario: "video-failure", [request(fake)])

        #expect(items.map(\.state) == [.alreadyDownloaded(file: file(fake, "Fake Video abc123.mp4"))])
    }

    @Test func otherVideosOfTheBatchStillDownload() async throws {
        let fake = try FakeYtDlp()
        _ = await batch(fake, [request(fake, id: "abc123")])

        let items = await batch(fake, [request(fake, id: "abc123"), request(fake, id: "def456")])

        #expect(items.map(\.state) == [
            .alreadyDownloaded(file: file(fake, "Fake Video abc123.mp4")),
            .finished(file: file(fake, "Fake Video def456.mp4")),
        ])
    }

    @Test func aQualityPresetOrNamingPatternChangeNeverDownloadsAgain() async throws {
        let fake = try FakeYtDlp()
        _ = await batch(fake, [request(fake, quality: .best, naming: .title)])

        let items = await batch(fake, [request(fake, quality: .p720, naming: .dateTitle)])

        #expect(items.map(\.state) == [.alreadyDownloaded(file: file(fake, "Fake Video abc123.mp4"))])
    }

    @Test func aRenamedFileStillCounts() async throws {
        let fake = try FakeYtDlp()
        _ = await batch(fake, [request(fake)])
        try FileManager.default.createDirectory(at: file(fake, "Keep"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file(fake, "Fake Video abc123.mp4"), to: file(fake, "Keep/zoo.mp4"))

        let items = await batch(fake, [request(fake)])

        #expect(items.map(\.state) == [.alreadyDownloaded(file: file(fake, "Keep/zoo.mp4"))])
    }

    @Test func theOtherFormatDownloads() async throws {
        let fake = try FakeYtDlp()
        _ = await batch(fake, [request(fake, format: .video)])

        let items = await batch(fake, [request(fake, format: .mp3)])

        #expect(items.map(\.state) == [.finished(file: file(fake, "Fake Video abc123.mp3"))])
    }

    @Test func aMovedOutOrDeletedFileDownloadsAgain() async throws {
        let fake = try FakeYtDlp()
        _ = await batch(fake, [request(fake)])
        try FileManager.default.removeItem(at: file(fake, "Fake Video abc123.mp4"))

        let items = await batch(fake, [request(fake)])

        #expect(items.map(\.state) == [.finished(file: file(fake, "Fake Video abc123.mp4"))])
    }

    @Test func theSameVideoTwiceInOneBatchDownloadsOnce() async throws {
        let fake = try FakeYtDlp()

        let items = await batch(fake, [request(fake), request(fake, naming: .dateTitle)])

        let saved = file(fake, "Fake Video abc123.mp4")
        #expect(items.map(\.state) == [.finished(file: saved), .alreadyDownloaded(file: saved)])
        #expect(savedFiles(fake) == ["Fake Video abc123.mp4"])
    }

    @Test func skippedRowsShowAtOnceWhileAnotherVideoDownloads() async throws {
        let fake = try FakeYtDlp()
        _ = await batch(fake, [request(fake, id: "abc123")])
        let queue = Queue(runner: fake.runner(scenario: "slow", extraEnvironment: ["YT4S_FAKE_STEP_DELAY": "0.3"]))

        queue.add(request(fake, id: "def456"))
        let deadline = ContinuousClock.now + .seconds(5)
        while queue.items[0].state == .pending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        queue.add(request(fake, id: "abc123"))

        // Not after the running download: the moment it is added.
        #expect(queue.items[1].state == .alreadyDownloaded(file: file(fake, "Fake Video abc123.mp4")))
        #expect(queue.items[0].isActive)
        await queue.waitUntilIdle()
    }

    @Test func downloadAgainWritesASecondFileAndKeepsTheFirst() async throws {
        let fake = try FakeYtDlp()
        let original = file(fake, "Fake Video abc123.mp4")
        _ = await batch(fake, [request(fake)])
        try "the first copy".write(to: original, atomically: false, encoding: .utf8)
        let queue = Queue(runner: fake.runner(scenario: "success"))
        let id = queue.add(request(fake))
        await queue.waitUntilIdle()

        queue.downloadAgain(id)
        await queue.waitUntilIdle()

        #expect(queue.items[0].state == .finished(file: file(fake, "Fake Video abc123 [abc123].mp4")))
        #expect(savedFiles(fake) == ["Fake Video abc123 [abc123].mp4", "Fake Video abc123.mp4"])
        #expect(try String(contentsOf: original, encoding: .utf8) == "the first copy")
    }

    @Test func downloadAgainOnlyAppliesToAlreadyDownloadedRows() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "success"))
        let id = queue.add(request(fake))
        await queue.waitUntilIdle()

        queue.downloadAgain(id)
        await queue.waitUntilIdle()

        #expect(queue.items[0].state == .finished(file: file(fake, "Fake Video abc123.mp4")))
        #expect(savedFiles(fake) == ["Fake Video abc123.mp4"])
    }
}
