import Foundation
import Observation

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

    public init(id: UUID = UUID(), request: DownloadRequest, title: String? = nil, videoID: String? = nil, state: QueueItemState = .pending) {
        self.id = id
        self.request = request
        self.title = title
        self.videoID = videoID
        self.state = state
    }

    public var isFinished: Bool { if case .finished = state { true } else { false } }
    public var isFailed: Bool { if case .failed = state { true } else { false } }
    /// What Retry accepts: a cancelled row, or a failure that can succeed again.
    public var isRetryable: Bool {
        switch state {
        case .failed(let failure): failure.category.isRetryable
        case .cancelled: true
        case .pending, .running, .finished, .alreadyDownloaded: false
        }
    }
    /// Waiting or running: yt-dlp has work left to do for it.
    public var isActive: Bool {
        switch state {
        case .pending, .running: true
        case .finished, .alreadyDownloaded, .failed, .cancelled: false
        }
    }

    /// Finished or Already downloaded: what "Clear finished" removes.
    public var isDone: Bool {
        switch state {
        case .finished, .alreadyDownloaded: true
        case .pending, .running, .failed, .cancelled: false
        }
    }
}

/// The visible list of pending, running, finished and failed downloads.
///
/// Videos run one at a time, in the order added, each as one yt-dlp run built by
/// `DownloadArguments`. All state changes happen on the main actor, in the order yt-dlp reports them.
@MainActor @Observable
public final class Queue {
    public private(set) var items: [QueueItem] = []

    /// Also lists Playlist and Channel sources, so both use the same yt-dlp.
    @ObservationIgnored let runner: YtDlpRunner
    /// Called each time the Queue runs out of work, with the summary at that moment.
    /// The app posts the batch notification from here when it is in the background.
    @ObservationIgnored public var onBatchFinished: (@MainActor (QueueSummary) -> Void)?
    @ObservationIgnored private let partialFilesFolder: URL
    /// Wait before the one automatic retry of a Network failure.
    @ObservationIgnored private let networkRetryDelay: Duration
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// The item yt-dlp is working on, with the task to cancel to stop it.
    @ObservationIgnored private var current: (id: QueueItem.ID, task: Task<Void, Never>)?

    /// - Parameter partialFilesFolder: where yt-dlp keeps unfinished files (`-P temp:`), one
    ///   subfolder per item, so they never show up in the Download folder and Cancel / Retry can
    ///   delete them all.
    /// - Parameter networkRetryDelay: how long a Network failure waits before its one automatic retry.
    public init(
        runner: YtDlpRunner,
        partialFilesFolder: URL = Queue.defaultPartialFilesFolder,
        networkRetryDelay: Duration = .seconds(5)
    ) {
        self.runner = runner
        self.partialFilesFolder = partialFilesFolder
        self.networkRetryDelay = networkRetryDelay
    }

    public nonisolated static var defaultPartialFilesFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("YT4S-partial", isDirectory: true)
    }

    /// Appends a pending item and starts it when its turn comes.
    @discardableResult
    public func add(_ request: DownloadRequest) -> QueueItem.ID {
        let item = QueueItem(request: request, title: request.origin.title, videoID: request.origin.videoID)
        items.append(item)
        startWorkerIfNeeded()
        return item.id
    }

    /// Returns once no item is pending or running.
    public func waitUntilIdle() async {
        // The worker clears itself when done; a new one may start if items were added meanwhile.
        while let worker {
            await worker.value
        }
    }

    public var isIdle: Bool { worker == nil }

    /// True while any video is waiting or running. Derived from `items`, so it is observable:
    /// both footer update buttons disable themselves on it (ADR 0002).
    public var hasActiveDownloads: Bool { items.contains(where: \.isActive) }

    /// Stops a pending or running item and deletes its partial files. No effect on other states.
    public func cancel(_ id: QueueItem.ID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch item.state {
        case .pending:
            update(id) { $0.state = .cancelled }
        case .running:
            if current?.id == id { current?.task.cancel() }
        case .finished, .alreadyDownloaded, .failed, .cancelled:
            break
        }
    }

    /// Removes every finished and Already downloaded row. Files on disk are never touched.
    public func clearFinished() {
        items.removeAll(where: \.isDone)
    }

    /// Removes one row that is not waiting or running. Files on disk are never touched.
    public func remove(_ id: QueueItem.ID) {
        items.removeAll { $0.id == id && !$0.isActive }
    }

    /// Re-runs a failed or cancelled item with its original request (Format, Quality preset,
    /// Naming pattern, Download folder), deleting its partial files first. No effect on other states.
    /// Failures that cannot succeed again (Unavailable, Region-blocked) are left alone too.
    public func retry(_ id: QueueItem.ID) {
        guard let item = items.first(where: { $0.id == id }), item.isRetryable else { return }
        deletePartialFiles(partialFilesFolder(for: id))
        update(id) { $0.state = .pending }
        startWorkerIfNeeded()
    }

    /// Retries every failed row that can succeed again ("Retry all failed"). Cancelled rows stay.
    public func retryAllFailed() {
        for item in items where item.isFailed && item.isRetryable {
            retry(item.id)
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        // Keeps App Nap from throttling the Queue (and idle sleep from cutting downloads short)
        // while YT4S is in the background, so rows and the batch notification stay on time.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Downloading videos")
        worker = Task { [weak self] in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            while let self, let next = self.items.first(where: { $0.state == .pending }) {
                let task = Task { await self.download(next.id) }
                self.current = (next.id, task)
                await task.value
                self.current = nil
            }
            guard let self else { return }
            self.worker = nil
            self.onBatchFinished?(QueueSummary(self.items))
        }
    }

    /// Runs one item; a Network failure is retried once, after `networkRetryDelay`, before the
    /// row shows it. The row stays running meanwhile, and Cancel still stops it.
    private func download(_ id: QueueItem.ID) async {
        await attempt(id)
        guard case .failed(let failure) = items.first(where: { $0.id == id })?.state,
              failure.category == .network, !Task.isCancelled else { return }
        update(id) { $0.state = .running(DownloadProgress()) }
        do {
            try await Task.sleep(for: networkRetryDelay)
        } catch {
            update(id) { $0.state = .cancelled }
            return
        }
        await attempt(id)
    }

    private func attempt(_ id: QueueItem.ID) async {
        guard let request = items.first(where: { $0.id == id })?.request else { return }
        var progress = DownloadProgress()
        var file: URL?
        update(id) { $0.state = .running(progress) }
        let partialFiles = partialFilesFolder(for: id)
        deletePartialFiles(partialFiles)
        defer {
            deletePartialFiles(partialFiles)
            // A cancelled run may end in an error or in nothing at all; only a finish beats Cancel.
            if Task.isCancelled { update(id) { if !$0.isFinished { $0.state = .cancelled } } }
        }

        do {
            let arguments = ["-P", "temp:" + partialFiles.path] + DownloadArguments.arguments(for: request)
            for try await update in runner.run(arguments) {
                switch update {
                case .event(let event):
                    progress.apply(event)
                    switch event {
                    case .video(let info):
                        self.update(id) { $0.title = info.title; $0.videoID = info.id }
                    case .file(_, let path):
                        file = URL(fileURLWithPath: path)
                    case .progress, .entry:
                        break
                    }
                    self.update(id) { $0.state = .running(progress) }
                case .exited(let exit):
                    self.update(id) {
                        if exit.succeeded, let file {
                            $0.state = .finished(file: file)
                        } else {
                            $0.state = .failed(DownloadFailure(termination: exit.termination, details: exit.stderr))
                        }
                    }
                }
            }
        } catch {
            update(id) { $0.state = .failed(DownloadFailure(termination: nil, details: String(describing: error))) }
        }
    }

    func partialFilesFolder(for id: QueueItem.ID) -> URL {
        partialFilesFolder.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Best effort: a leftover only wastes space in the temporary folder, never shows to the user.
    private func deletePartialFiles(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    private func update(_ id: QueueItem.ID, _ change: (inout QueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}
