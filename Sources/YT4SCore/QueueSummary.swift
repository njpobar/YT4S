import Foundation

/// The Queue header line, e.g. "42 downloaded, 3 already downloaded, 2 failed".
public struct QueueSummary: Equatable, Sendable {
    /// Waiting or running.
    public var active = 0
    public var downloaded = 0
    public var alreadyDownloaded = 0
    public var failed = 0
    public var cancelled = 0
    public var notStarted = 0
    /// Failed rows that Retry can help, plus Not started rows (Retry all failed resumes them);
    /// "Retry all failed" shows when there are 2 or more.
    public var retryableFailures = 0
    /// Whether "Clear finished" has anything to remove.
    public var hasFinished: Bool

    public init(_ items: [QueueItem]) {
        hasFinished = items.contains(where: \.isDone)
        for item in items {
            switch item.state {
            case .pending, .running: active += 1
            case .finished: downloaded += 1
            case .alreadyDownloaded: alreadyDownloaded += 1
            case .failed(let failure):
                failed += 1
                if failure.category.isRetryable { retryableFailures += 1 }
            case .cancelled: cancelled += 1
            case .notStarted:
                notStarted += 1
                retryableFailures += 1
            }
        }
    }

    /// Non-zero counts only, what is still going first; empty for an empty Queue.
    public var text: String {
        [
            (active, "active"),
            (downloaded, "downloaded"),
            (alreadyDownloaded, "already downloaded"),
            (failed, "failed"),
            (cancelled, "cancelled"),
            (notStarted, "not started"),
        ]
        .filter { $0.0 > 0 }
        .map { "\($0.0) \($0.1)" }
        .joined(separator: ", ")
    }
}
