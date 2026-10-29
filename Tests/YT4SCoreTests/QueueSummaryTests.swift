import Foundation
import Testing
@testable import YT4SCore

/// The Queue header line that sums up the batch.
@Suite struct QueueSummaryTests {
    private let request = DownloadRequest(
        url: "https://youtu.be/jNQXAC9IVRw",
        downloadFolder: URL(fileURLWithPath: "/tmp/YT4S", isDirectory: true),
        options: .default
    )
    private let file = URL(fileURLWithPath: "/tmp/YT4S/Me at the zoo.mp4")

    private func items(_ states: [QueueItemState]) -> [QueueItem] {
        states.map { QueueItem(request: request, state: $0) }
    }

    private var failure: QueueItemState { .failed(DownloadFailure(termination: .exited(1), details: "ERROR")) }

    @Test func countsEachOutcome() {
        let summary = QueueSummary(items(
            Array(repeating: .finished(file: file), count: 42)
                + Array(repeating: .alreadyDownloaded(file: file), count: 3)
                + [failure, failure]
        ))

        #expect(summary.text == "42 downloaded, 3 already downloaded, 2 failed")
    }

    @Test func leavesOutZeroCountsAndLeadsWithWhatIsStillGoing() {
        let summary = QueueSummary(items([
            .running(DownloadProgress()), .pending, .pending, .finished(file: file), .cancelled,
        ]))

        #expect(summary.text == "3 active, 1 downloaded, 1 cancelled")
    }

    @Test func offersRetryAllFailedForASingleRetryableFailure() {
        #expect(QueueSummary(items([.finished(file: file), failure])).showsRetryAllFailed)
        #expect(QueueSummary(items([.notStarted])).showsRetryAllFailed)
    }

    @Test func doesNotOfferRetryAllFailedWithoutRetryableFailures() {
        let unavailable = QueueItemState.failed(DownloadFailure(termination: .exited(1), details: "ERROR: Video unavailable"))
        #expect(!QueueSummary(items([.finished(file: file), .cancelled, unavailable])).showsRetryAllFailed)
    }

    @Test func isEmptyForAnEmptyQueue() {
        #expect(QueueSummary([]).text == "")
    }

    @Test func knowsWhetherAnythingCanBeCleared() {
        #expect(!QueueSummary(items([.pending, failure, .cancelled])).hasFinished)
        #expect(QueueSummary(items([.alreadyDownloaded(file: file)])).hasFinished)
        #expect(QueueSummary(items([.finished(file: file)])).hasFinished)
    }
}
