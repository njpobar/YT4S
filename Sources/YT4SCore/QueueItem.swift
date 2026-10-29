import Foundation

/// Why a Queue item failed.
public struct DownloadFailure: Equatable, Sendable {
    /// How yt-dlp ended; `nil` when it could not be launched at all.
    public var termination: SubprocessTermination?
    /// Raw yt-dlp stderr (or the launch error), for the Details disclosure. Never shown in the row.
    public var details: String
    /// Derived from `details` and `termination`: decides the row sentence and whether Retry helps.
    public var category: FailureCategory

    public init(termination: SubprocessTermination?, details: String) {
        self.termination = termination
        self.details = details
        category = FailureCategory(stderr: details, termination: termination)
    }
}

public enum QueueItemState: Equatable, Sendable {
    case pending
    case running(DownloadProgress)
    case finished(file: URL)
    /// Skipped because its Format is already in the Download folder (set by skip detection, #24).
    case alreadyDownloaded(file: URL)
    case failed(DownloadFailure)
    /// Stopped by the user before it finished; its partial files are gone.
    case cancelled
    /// Never run: the batch stopped early after 3 Looks-outdated failures in a row (#11). Retry resumes it.
    case notStarted
}

/// One video in the Queue.
public struct QueueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// What to download and how. Kept so Retry re-runs with the original choices.
    public let request: DownloadRequest
    /// From yt-dlp once it has looked the video up; `nil` until then.
    public var title: String?
    public var videoID: String?
    public var state: QueueItemState
    /// The file the video will be saved as (Naming pattern + collision rule), predicted once
    /// yt-dlp has looked the video up and before it downloads; `nil` until then.
    public var plannedFile: URL?
    /// Set by Download again: skip detection leaves it alone and it is saved as a new file under
    /// the collision rule, never over the copy already there.
    public internal(set) var downloadAgain = false

    public init(id: UUID = UUID(), request: DownloadRequest, title: String? = nil, videoID: String? = nil, state: QueueItemState = .pending) {
        self.id = id
        self.request = request
        self.title = title
        self.videoID = videoID
        self.state = state
    }

    public var isFinished: Bool { if case .finished = state { true } else { false } }
    public var isAlreadyDownloaded: Bool { if case .alreadyDownloaded = state { true } else { false } }
    public var isFailed: Bool { if case .failed = state { true } else { false } }
    /// What Retry accepts: a cancelled row, or a failure that can succeed again.
    public var isRetryable: Bool {
        switch state {
        case .failed(let failure): failure.category.isRetryable
        case .cancelled, .notStarted: true
        case .pending, .running, .finished, .alreadyDownloaded: false
        }
    }
    /// Waiting or running: yt-dlp has work left to do for it.
    public var isActive: Bool {
        switch state {
        case .pending, .running: true
        case .finished, .alreadyDownloaded, .failed, .cancelled, .notStarted: false
        }
    }

    /// Finished or Already downloaded: what "Clear finished" removes.
    public var isDone: Bool {
        switch state {
        case .finished, .alreadyDownloaded: true
        case .pending, .running, .failed, .cancelled, .notStarted: false
        }
    }
}
