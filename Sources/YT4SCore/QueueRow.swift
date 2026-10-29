import Foundation

/// What one Queue row displays, derived from its `QueueItem`. Kept out of the view so it is tested.
public struct QueueRow: Equatable, Sendable {
    public enum Tone: Sendable {
        case normal, success, failure, skipped
    }

    /// A button on the row, in display order.
    public enum Action: Equatable, Sendable {
        case cancel
        case retry
        case remove
        case showInFinder(URL)
    }

    public var title: String
    public var status: String
    public var tone: Tone
    /// Bar fill while running; `nil` means indeterminate or no bar.
    public var fraction: Double?
    public var showsProgress: Bool
    public var actions: [Action]

    public init(_ item: QueueItem) {
        title = item.title ?? item.request.url
        fraction = nil
        showsProgress = false
        tone = .normal
        actions = []
        switch item.state {
        case .pending:
            status = "Waiting"
            actions = [.cancel]
        case .running(let progress):
            actions = [.cancel]
            showsProgress = true
            fraction = progress.fraction
            status = Self.runningStatus(progress)
        case .finished(let file):
            status = "Done"
            tone = .success
            actions = [.showInFinder(file)]
        case .failed:
            // Placeholder until the failure categories ticket gives one sentence per category.
            status = "Couldn't download this video."
            tone = .failure
            actions = [.retry]
        case .alreadyDownloaded(let file):
            status = "Already downloaded"
            tone = .skipped
            actions = [.showInFinder(file)]
        case .cancelled:
            status = "Cancelled"
            actions = [.retry, .remove]
        }
    }

    private static func runningStatus(_ progress: DownloadProgress) -> String {
        guard let fraction = progress.fraction else { return "Starting..." }
        var parts = ["\(Int((fraction * 100).rounded(.down)))%"]
        if let speed = progress.speed, speed > 0 { parts.append(speedText(speed)) }
        if let eta = progress.eta, fraction < 1 { parts.append(etaText(eta)) }
        return parts.joined(separator: " - ")
    }

    private static func speedText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        return "\(Int((bytesPerSecond / 1000).rounded())) KB/s"
    }

    private static func etaText(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s left" : "\(seconds / 60)m \(seconds % 60)s left"
    }
}
