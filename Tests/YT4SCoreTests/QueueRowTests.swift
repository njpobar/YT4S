import Foundation
import Testing
@testable import YT4SCore

/// The text a Queue row shows for each state.
@Suite struct QueueRowTests {
    private let request = DownloadRequest(
        url: "https://youtu.be/jNQXAC9IVRw",
        downloadFolder: URL(fileURLWithPath: "/tmp/YT4S", isDirectory: true),
        options: .default
    )

    private func progress(fraction: Double, speed: Double, eta: Int) -> DownloadProgress {
        var progress = DownloadProgress()
        progress.apply(.progress(PartProgress(
            videoID: "x", formatID: "18", status: .downloading,
            downloadedBytes: Int64(fraction * 1000), totalBytes: 1000, totalBytesEstimate: nil,
            speed: speed, eta: eta, fragmentIndex: nil, fragmentCount: nil
        )))
        return progress
    }

    @Test func showsTheLinkUntilTheTitleIsKnown() {
        #expect(QueueRow(QueueItem(request: request)).title == "https://youtu.be/jNQXAC9IVRw")
        #expect(QueueRow(QueueItem(request: request, title: "Me at the zoo")).title == "Me at the zoo")
    }

    @Test func statusPerState() {
        let file = URL(fileURLWithPath: "/tmp/YT4S/Me at the zoo.mp4")
        #expect(QueueRow(QueueItem(request: request)).status == "Waiting")
        #expect(QueueRow(QueueItem(request: request, state: .running(DownloadProgress()))).status == "Starting...")
        #expect(QueueRow(QueueItem(request: request, state: .finished(file: file))).status == "Done")
        #expect(QueueRow(QueueItem(request: request, state: .failed(DownloadFailure(termination: .exited(1), details: "ERROR: x")))).status
            == "Something went wrong. Retry, or check Details for what yt-dlp said.")
    }

    @Test func runningStatusShowsPercentSpeedAndTimeLeft() {
        let row = QueueRow(QueueItem(request: request, state: .running(progress(fraction: 0.4, speed: 3_200_000, eta: 5))))

        #expect(row.status == "40% - 3.2 MB/s - 5s left")
        #expect(row.fraction == 0.4)
    }

    @Test func slowSpeedsAndLongWaitsReadNaturally() {
        let row = QueueRow(QueueItem(request: request, state: .running(progress(fraction: 0.07, speed: 850_000, eta: 125))))

        #expect(row.status == "7% - 850 KB/s - 2m 5s left")
    }

    @Test func onlyRunningRowsHaveAProgressBar() {
        #expect(QueueRow(QueueItem(request: request)).fraction == nil)
        #expect(QueueRow(QueueItem(request: request, state: .running(DownloadProgress()))).showsProgress)
        #expect(!QueueRow(QueueItem(request: request)).showsProgress)
    }

    @Test func stoppedRowsSayWhy() {
        let file = URL(fileURLWithPath: "/tmp/YT4S/Me at the zoo.mp4")
        #expect(QueueRow(QueueItem(request: request, state: .cancelled)).status == "Cancelled")
        #expect(QueueRow(QueueItem(request: request, state: .alreadyDownloaded(file: file))).status == "Already downloaded")
        #expect(QueueRow(QueueItem(request: request, state: .alreadyDownloaded(file: file))).tone == .skipped)
    }

    @Test func eachStateOffersItsActions() {
        let file = URL(fileURLWithPath: "/tmp/YT4S/Me at the zoo.mp4")
        func actions(_ state: QueueItemState) -> [QueueRow.Action] {
            QueueRow(QueueItem(request: request, state: state)).actions
        }

        #expect(actions(.pending) == [.cancel])
        #expect(actions(.running(DownloadProgress())) == [.cancel])
        #expect(actions(.finished(file: file)) == [.showInFinder(file)])
        #expect(actions(.alreadyDownloaded(file: file)) == [.showInFinder(file)])
        #expect(actions(.failed(DownloadFailure(termination: .exited(1), details: "ERROR: x"))) == [.retry])
        #expect(actions(.cancelled) == [.retry, .remove])
    }

    private func failedRow(_ stderr: String) -> QueueRow {
        QueueRow(QueueItem(request: request, state: .failed(DownloadFailure(termination: .exited(1), details: stderr))))
    }

    @Test func aFailedRowSaysWhyAndWhatToDoNeverTheRawText() throws {
        let stderr = try StderrFixture.text("connection-refused")
        let row = failedRow(stderr)

        #expect(row.status == "Couldn't reach YouTube. Check your internet connection, then Retry.")
        #expect(!row.status.contains("ERROR"))
        #expect(row.tone == .failure)
    }

    @Test func aFailedRowKeepsTheRawOutputForDetails() throws {
        let stderr = try StderrFixture.text("disk-full")

        #expect(failedRow(stderr).details == stderr)
        #expect(QueueRow(QueueItem(request: request)).details == nil)
        #expect(QueueRow(QueueItem(request: request, state: .cancelled)).details == nil)
    }

    @Test(arguments: [
        ("unavailable-video", [QueueRow.Action]()),
        ("from-source/region-blocked", []),
        ("connection-refused", [.retry]),
        ("disk-full", [.retry]),
        ("from-source/bot-check", [.retry]),
        ("from-source/postprocessing-failed", [.retry]),
    ])
    func onlyFailuresThatCanSucceedAgainOfferRetry(fixture: String, expected: [QueueRow.Action]) throws {
        #expect(failedRow(try StderrFixture.text(fixture)).actions == expected)
    }
}
