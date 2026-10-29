import Foundation
import Observation

/// Why a Queue item failed.
///
/// A generic placeholder for now: the failure categories ticket adds a category (Unavailable,
/// Network, Looks outdated, ...) derived from `details` and `termination`, and the row sentence.
public struct DownloadFailure: Equatable, Sendable {
    /// How yt-dlp ended; `nil` when it could not be launched at all.
    public var termination: SubprocessTermination?
    /// Raw yt-dlp stderr (or the launch error), for the Details disclosure. Never shown in the row.
    public var details: String

    public init(termination: SubprocessTermination?, details: String) {
        self.termination = termination
        self.details = details
    }
}

public enum QueueItemState: Equatable, Sendable {
    case pending
    case running(DownloadProgress)
    case finished(file: URL)
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
}

/// The visible list of pending, running, finished and failed downloads.
///
/// Videos run one at a time, in the order added, each as one yt-dlp run built by
/// `DownloadArguments`. All state changes happen on the main actor, in the order yt-dlp reports them.
@MainActor @Observable
public final class Queue {
    public private(set) var items: [QueueItem] = []

    @ObservationIgnored private let runner: YtDlpRunner
    @ObservationIgnored private let partialFilesFolder: URL
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// The item yt-dlp is working on, with the task to cancel to stop it.
    @ObservationIgnored private var current: (id: QueueItem.ID, task: Task<Void, Never>)?

    /// - Parameter partialFilesFolder: where yt-dlp keeps unfinished files (`-P temp:`), one
    ///   subfolder per item, so they never show up in the Download folder and Cancel / Retry can
    ///   delete them all.
    public init(runner: YtDlpRunner, partialFilesFolder: URL = Queue.defaultPartialFilesFolder) {
        self.runner = runner
        self.partialFilesFolder = partialFilesFolder
    }

    public nonisolated static var defaultPartialFilesFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("YT4S-partial", isDirectory: true)
    }

    /// Appends a pending item and starts it when its turn comes.
    @discardableResult
    public func add(_ request: DownloadRequest) -> QueueItem.ID {
        let item = QueueItem(request: request)
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

    /// Stops a pending or running item and deletes its partial files. No effect on other states.
    public func cancel(_ id: QueueItem.ID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch item.state {
        case .pending:
            update(id) { $0.state = .cancelled }
        case .running:
            if current?.id == id { current?.task.cancel() }
        case .finished, .failed, .cancelled:
            break
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.items.first(where: { $0.state == .pending }) {
                let task = Task { await self.download(next.id) }
                self.current = (next.id, task)
                await task.value
                self.current = nil
            }
            self?.worker = nil
        }
    }

    private func download(_ id: QueueItem.ID) async {
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
                    case .progress:
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
