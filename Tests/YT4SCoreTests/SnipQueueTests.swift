import Foundation
import Testing
@testable import YT4SCore

/// Snip on a Done Queue row, end to end: the real Queue and Snipper against the fake yt-dlp and
/// the fake ffmpeg (`Fixtures/fake-ffmpeg`, which writes the input plus "snipped\n").
@MainActor @Suite(.timeLimit(.minutes(1))) struct SnipQueueTests {
    private let plan = SnipPlan(duration: 3, cuts: [Cut(start: 1, end: 2)])

    private func request(_ fake: FakeYtDlp, id: String = "abc123", format: Format = .video) -> DownloadRequest {
        var options = DownloadOptions.default
        options.format = format
        return DownloadRequest(url: "https://www.youtube.com/watch?v=\(id)", downloadFolder: fake.downloadFolder, options: options)
    }

    /// A Queue with one Done row, downloaded through the fake yt-dlp.
    private func finishedRow(
        _ fake: FakeYtDlp, format: Format = .video, environment: [String: String] = [:]
    ) async throws -> (Queue, QueueItem.ID, URL) {
        let queue = Queue(runner: fake.runner(scenario: "success", extraEnvironment: environment))
        let id = queue.add(request(fake, format: format))
        await queue.waitUntilIdle()
        guard case .finished(let file) = queue.item(id)?.state else {
            throw FixtureError.missing("a finished row, got \(String(describing: queue.item(id)?.state))")
        }
        return (queue, id, file)
    }

    private func snippedCopy(_ queue: Queue, _ id: QueueItem.ID) -> URL? {
        if case .snipped(let copy) = queue.item(id)?.snip { copy } else { nil }
    }

    @Test func aSnipSavesASnippedCopyNextToTheOriginalAndLeavesTheOriginalAlone() async throws {
        let fake = try FakeYtDlp()
        let (queue, id, original) = try await finishedRow(fake)
        let originalBytes = try Data(contentsOf: original)

        queue.snip(id, plan: plan)
        await queue.waitUntilSnipsFinished()

        let copy = fake.downloadFolder.appendingPathComponent("Fake Video abc123 (snipped).mp4")
        #expect(queue.item(id)?.snip == .snipped(copy: copy))
        #expect(queue.item(id)?.state == .finished(file: original))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try Data(contentsOf: copy) == originalBytes + Data("snipped\n".utf8))
        #expect(QueueRow(queue.item(id)!).actions == [.snip, .showInFinder([original, copy])])
    }

    @Test(arguments: Format.allCases)
    func theSnippedCopyIsTaggedWithTheOriginalsVideoAndFormat(format: Format) async throws {
        let fake = try FakeYtDlp()
        let (queue, id, original) = try await finishedRow(fake, format: format)

        queue.snip(id, plan: plan)
        await queue.waitUntilSnipsFinished()

        let copy = try #require(snippedCopy(queue, id))
        #expect(copy.pathExtension == original.pathExtension)
        let folder = DownloadFolder(url: fake.downloadFolder)
        #expect(folder.savedVideo(ofFileAt: copy) == SavedVideo(videoID: "abc123", format: format))
        #expect(folder.savedVideo(ofFileAt: copy) == folder.savedVideo(ofFileAt: original))
    }

    @Test func ffmpegWritesInsideTheHiddenIncompleteFolderAndLeavesNothingThere() async throws {
        let fake = try FakeYtDlp()
        let (queue, id, original) = try await finishedRow(fake, environment: ["YT4S_FAKE_FFMPEG_ARGV_LOG": fake.ffmpegArgvLog.path])

        queue.snip(id, plan: plan)
        await queue.waitUntilSnipsFinished()

        let argv = try String(contentsOf: fake.ffmpegArgvLog, encoding: .utf8)
            .split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        let output = try #require(argv.last.map(URL.init(fileURLWithPath:)))
        let incomplete = DownloadFolder(url: fake.downloadFolder).incompleteFolder
        #expect(output.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == incomplete.standardizedFileURL)
        #expect(argv == SnipArguments.arguments(input: original, output: output, format: .video, plan: plan))
        #expect(!FileManager.default.fileExists(atPath: incomplete.path))
    }

    @Test func aSnippingRowShowsItsProgress() async throws {
        let fake = try FakeYtDlp()
        let hold = fake.holdSnip()
        defer { try? hold.release() }
        var environment = hold.environment
        environment["YT4S_FAKE_FFMPEG_OUT_TIMES"] = "1260000 2000000"
        let (queue, id, _) = try await finishedRow(fake, environment: environment)

        // Kept: 2 of the 3 seconds; ffmpeg has written 1.26 s of them.
        queue.snip(id, plan: plan)
        try await waitUntil { queue.item(id)?.snip == .snipping(fraction: 0.63) }
        #expect(QueueRow(queue.item(id)!).status == "Snipping 63%")

        try hold.release()
        await queue.waitUntilSnipsFinished()
        #expect(QueueRow(queue.item(id)!).status == "Done - snipped")
    }

    @Test func snippingAgainStartsFromTheOriginalAndNumbersTheCopy() async throws {
        let fake = try FakeYtDlp()
        let (queue, id, original) = try await finishedRow(fake)
        let originalBytes = try Data(contentsOf: original)

        queue.snip(id, plan: plan)
        await queue.waitUntilSnipsFinished()
        queue.snip(id, plan: plan)
        await queue.waitUntilSnipsFinished()

        let second = fake.downloadFolder.appendingPathComponent("Fake Video abc123 (snipped) 2.mp4")
        #expect(queue.item(id)?.snip == .snipped(copy: second))
        #expect(try Data(contentsOf: second) == originalBytes + Data("snipped\n".utf8))
    }

    @Test func aSnipRunsWhileADownloadContinuesAndIsNeverCountedAsOne() async throws {
        let fake = try FakeYtDlp()
        let held = try await finishedRowThenHeldDownload(fake)
        defer { try? held.hold.release() }

        held.queue.snip(held.done, plan: plan)
        await held.queue.waitUntilSnipsFinished()
        #expect(snippedCopy(held.queue, held.done) != nil)
        #expect(held.queue.item(held.downloading)?.isActive == true)
        #expect(QueueSummary(held.queue.items).text == "1 active, 1 downloaded")

        try held.hold.release()
        await held.queue.waitUntilIdle()
        #expect(held.reports() == ["2 downloaded"])
    }

    @Test func finishingASnipNeverPostsTheBatchNotification() async throws {
        let fake = try FakeYtDlp()
        let (queue, id, _) = try await finishedRow(fake)
        var reports: [String] = []
        queue.onBatchFinished = { reports.append($0.text) }

        queue.snip(id, plan: plan)
        await queue.waitUntilSnipsFinished()

        #expect(reports.isEmpty)
        #expect(QueueSummary(queue.items).text == "1 downloaded")
    }

    @Test func clearFinishedKeepsARowThatIsSnipping() async throws {
        let fake = try FakeYtDlp()
        let hold = fake.holdSnip()
        defer { try? hold.release() }
        let (queue, id, _) = try await finishedRow(fake, environment: hold.environment)

        queue.snip(id, plan: plan)
        try await waitUntil { queue.item(id)?.isSnipping == true }
        queue.clearFinished()
        #expect(queue.item(id) != nil)

        try hold.release()
        await queue.waitUntilSnipsFinished()
        queue.clearFinished()
        #expect(queue.items.isEmpty)
    }

    @Test func onlyDoneRowsCanBeSnipped() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "video-failure"))
        let id = queue.add(request(fake))
        await queue.waitUntilIdle()

        queue.snip(id, plan: plan)
        await queue.waitUntilSnipsFinished()

        #expect(queue.item(id)?.snip == nil)
    }

    @Test func aSnipThatFailsLeavesTheRowDoneAndNoPartialCopy() async throws {
        let fake = try FakeYtDlp()
        let (queue, id, original) = try await finishedRow(fake, environment: ["YT4S_FAKE_FFMPEG_FAIL": "No space left on device"])

        queue.snip(id, plan: plan)
        await queue.waitUntilSnipsFinished()

        #expect(queue.item(id)?.snip == nil)
        #expect(QueueRow(queue.item(id)!).status == "Done")
        let names = try FileManager.default.contentsOfDirectory(atPath: fake.downloadFolder.path)
        #expect(names == [original.lastPathComponent])
    }

    // MARK: - A download held while a Snip runs

    @MainActor private final class Reports {
        var texts: [String] = []
    }

    private struct HeldDownload {
        let queue: Queue
        let done: QueueItem.ID
        let downloading: QueueItem.ID
        let hold: FakeYtDlp.Hold
        let reports: () -> [String]
    }

    /// One Done row, then a second video held at 50% in the same Queue.
    private func finishedRowThenHeldDownload(_ fake: FakeYtDlp) async throws -> HeldDownload {
        let hold = fake.hold(at: 50)
        let queue = Queue(runner: fake.runner(scenario: "success", extraEnvironment: hold.environment))
        let reports = Reports()
        // The first video runs through the hold: released before it is added.
        try hold.release()
        let done = queue.add(request(fake, id: "first"))
        await queue.waitUntilIdle()
        try FileManager.default.removeItem(at: hold.releaseFile)
        queue.onBatchFinished = { reports.texts.append($0.text) }

        let downloading = queue.add(request(fake, id: "second"))
        try await waitUntil {
            if case .running(let progress) = queue.item(downloading)?.state { progress.fraction == 0.5 } else { false }
        }
        return HeldDownload(queue: queue, done: done, downloading: downloading, hold: hold, reports: { reports.texts })
    }
}
