import Foundation

/// What one Queue row displays, derived from its `QueueItem`. Kept out of the view so it is tested.
public struct QueueRow: Equatable, Sendable {
    public enum Tone: Sendable {
        case normal, success, failure
    }

    public var title: String
    public var status: String
    public var tone: Tone
    /// Bar fill while running; `nil` means indeterminate or no bar.
    public var fraction: Double?
    public var showsProgress: Bool

    public init(_ item: QueueItem) {
        title = item.title ?? item.request.url
        fraction = nil
        showsProgress = false
        tone = .normal
        switch item.state {
        case .pending:
            status = "Waiting"
        case .running(let progress):
            showsProgress = true
            fraction = progress.fraction
            status = Self.runningStatus(progress)
        case .finished:
            status = "Done"
            tone = .success
        case .failed:
            // Placeholder until the failure categories ticket gives one sentence per category.
            status = "Couldn't download this video."
            tone = .failure
        case .alreadyDownloaded:
            status = "Already downloaded"
        case .cancelled:
            status = "Cancelled"
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
