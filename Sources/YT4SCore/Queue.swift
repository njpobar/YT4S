import Foundation
import Observation

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
    /// What each Download folder already holds, scanned once per batch (a worker run) and kept up
    /// to date with what the batch saves. The folder is the only record (no ledger).
    @ObservationIgnored private var savedFiles: [URL: [SavedVideo: URL]] = [:]
    /// The Looks-outdated banner and early stop.
    private var outdated = OutdatedBatch()

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

    /// Whether the Looks-outdated banner shows (`OutdatedBanner`): 2 or more videos of the batch
    /// failed as Looks outdated, or the batch was a single video that did.
    public var showsOutdatedBanner: Bool { outdated.showsBanner }

    public func item(_ id: QueueItem.ID) -> QueueItem? {
        items.first { $0.id == id }
    }

    /// At launch, before anything downloads: removes what a quit mid-download left behind, i.e.
    /// yt-dlp's unfinished output in `downloadFolder` (only its hidden incomplete folder) and
    /// every partial file. Does nothing while the Queue runs.
    public func removeLeftovers(in downloadFolder: URL) {
        guard isIdle else { return }
        try? FileManager.default.removeItem(at: DownloadFolder(url: downloadFolder).incompleteFolder)
        deletePartialFiles(partialFilesFolder)
    }

    /// Appends a pending item and starts it when its turn comes.
    @discardableResult
    public func add(_ request: DownloadRequest) -> QueueItem.ID {
        let item = QueueItem(request: request, title: request.origin.title, videoID: request.origin.videoID)
        items.append(item)
        outdated.join(item.id, startsNewBatch: isIdle)
        skipIfAlreadyDownloaded(item.id)
        startWorkerIfNeeded()
        return item.id
    }

    /// Downloads an Already downloaded item anyway, as a new file under the collision rule
    /// (the copy already there is kept). No effect on other states.
    public func downloadAgain(_ id: QueueItem.ID) {
        guard item(id)?.isAlreadyDownloaded == true else { return }
        update(id) { $0.downloadAgain = true; $0.state = .pending }
        startWorkerIfNeeded()
    }

    /// Returns once no item is pending or running.
    public func waitUntilIdle() async {
        // The worker clears itself when done; a new one may start if items were added meanwhile.
        while let worker {
            await worker.value
        }
    }

    public var isIdle: Bool { worker == nil }

    /// True while any video is waiting or running. Derived from `items`, so it is observable.
    public var hasActiveDownloads: Bool { items.contains(where: \.isActive) }

    /// Stops a pending or running item and deletes its partial files. No effect on other states.
    public func cancel(_ id: QueueItem.ID) {
        guard let item = item(id) else { return }
        switch item.state {
        case .pending:
            update(id) { $0.state = .cancelled }
        case .running:
            if current?.id == id { current?.task.cancel() }
        case .finished, .alreadyDownloaded, .failed, .cancelled, .notStarted:
            break
        }
    }

    /// Removes every finished and Already downloaded row, and dismisses the Looks-outdated banner.
    /// Files on disk are never touched.
    public func clearFinished() {
        items.removeAll(where: \.isDone)
        dismissOutdatedBanner()
    }

    /// The banner's X. It shows again only after new Looks-outdated failures.
    public func dismissOutdatedBanner() {
        outdated.dismissBanner()
    }

    /// Removes one row that is not waiting or running. Files on disk are never touched.
    public func remove(_ id: QueueItem.ID) {
        items.removeAll { $0.id == id && !$0.isActive }
    }

    /// Re-runs a failed or cancelled item with its original request (Format, Quality preset,
    /// Naming pattern, Download folder), deleting its partial files first. No effect on other states.
    /// Failures that cannot succeed again (Unavailable, Region-blocked) are left alone too.
    public func retry(_ id: QueueItem.ID) {
        guard let item = item(id), item.isRetryable else { return }
        deletePartialFiles(partialFilesFolder(for: id))
        update(id) { $0.state = .pending }
        outdated.join(id, startsNewBatch: isIdle)
        startWorkerIfNeeded()
    }

    /// Retries every failed row that can succeed again ("Retry all failed"), and resumes the
    /// rows an early stop left Not started. Cancelled rows stay.
    public func retryAllFailed() {
        for item in items where (item.isFailed && item.isRetryable) || item.state == .notStarted {
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
            while let self {
                await self.scanDownloadFolders()
                for item in self.items where item.state == .pending { self.skipIfAlreadyDownloaded(item.id) }
                guard let next = self.items.first(where: { $0.state == .pending }) else { break }
                let task = Task { await self.download(next.id) }
                self.current = (next.id, task)
                await task.value
                self.current = nil
                self.recordOutcome(next.id)
            }
            guard let self else { return }
            self.worker = nil
            self.savedFiles = [:]
            self.onBatchFinished?(QueueSummary(self.items))
        }
    }

    /// Applies the Looks-outdated rules to an item that just stopped running; an early stop
    /// leaves every waiting video Not started.
    private func recordOutcome(_ id: QueueItem.ID) {
        guard let item = item(id), outdated.record(item, in: items) else { return }
        for index in items.indices where items[index].state == .pending {
            items[index].state = .notStarted
        }
    }

    /// Scans, off the main actor, each Download folder a pending item uses and this batch has not
    /// scanned yet.
    private func scanDownloadFolders() async {
        let folders = Set(items.filter { $0.state == .pending }.map(\.request.downloadFolder)).subtracting(savedFiles.keys)
        for folder in folders {
            savedFiles[folder] = await Task.detached { DownloadFolder(url: folder).savedFiles() }.value
        }
    }

    /// Marks a pending item Already downloaded when its Download folder holds its video in its
    /// Format (under any name, Quality preset or Naming pattern). Needs the folder scanned this
    /// batch; a file gone since the scan does not count.
    private func skipIfAlreadyDownloaded(_ id: QueueItem.ID) {
        guard let item = item(id), item.state == .pending, !item.downloadAgain,
              let videoID = item.request.origin.videoID else { return }
        let folder = item.request.downloadFolder
        let video = SavedVideo(videoID: videoID, format: item.request.options.format)
        guard let file = savedFiles[folder]?[video] else { return }
        guard DownloadFolder(url: folder).savedVideo(ofFileAt: file) == video else {
            savedFiles[folder]?[video] = nil
            return
        }
        update(id) { $0.state = .alreadyDownloaded(file: file) }
    }

    /// Runs one item; a Network failure is retried once, after `networkRetryDelay`, before the
    /// row shows it. The row stays running meanwhile, and Cancel still stops it.
    private func download(_ id: QueueItem.ID) async {
        await attempt(id)
        guard case .failed(let failure) = item(id)?.state, failure.category == .network, !Task.isCancelled else { return }
        update(id) { $0.state = .running(DownloadProgress()) }
        do {
            try await Task.sleep(for: networkRetryDelay)
        } catch {
            update(id) { $0.state = .cancelled }
            return
        }
        await attempt(id)
    }

    /// What one yt-dlp run of an item has reported so far.
    private struct Attempt {
        let request: DownloadRequest
        let downloadAgain: Bool
        var progress = DownloadProgress()
        /// yt-dlp's finished output in the incomplete folder, until it is placed.
        var file: URL?
        /// The video as yt-dlp looked it up, and its skip key.
        private(set) var video: (details: VideoDetails, saved: SavedVideo)?

        var downloadFolder: DownloadFolder { DownloadFolder(url: request.downloadFolder) }

        @discardableResult
        mutating func lookedUp(_ details: VideoDetails) -> SavedVideo {
            let saved = SavedVideo(videoID: details.id, format: request.options.format)
            video = (details, saved)
            return saved
        }
    }

    /// One yt-dlp run of an item, from start to its final state.
    private func attempt(_ id: QueueItem.ID) async {
        guard let item = item(id) else { return }
        var attempt = Attempt(request: item.request, downloadAgain: item.downloadAgain)
        update(id) { $0.state = .running(attempt.progress) }
        let partialFiles = partialFilesFolder(for: id)
        deletePartialFiles(partialFiles)
        defer {
            deletePartialFiles(partialFiles)
            if let file = attempt.file { attempt.downloadFolder.discardIncomplete(file) }
            // A cancelled run may end in an error or in nothing at all; only a finish beats Cancel.
            if Task.isCancelled { update(id) { if !$0.isDone { $0.state = .cancelled } } }
        }

        do {
            let arguments = ["-P", "temp:" + partialFiles.path] + DownloadArguments.arguments(for: attempt.request)
            for try await update in runner.run(arguments) {
                switch update {
                case .event(let event): apply(event, to: &attempt, of: id)
                case .exited(let exit): finish(id, &attempt, exit: exit)
                }
            }
        } catch {
            update(id) { $0.state = .failed(DownloadFailure(termination: nil, details: String(describing: error))) }
        }
    }

    private func apply(_ event: YtDlpEvent, to attempt: inout Attempt, of id: QueueItem.ID) {
        attempt.progress.apply(event)
        switch event {
        case .video(let info):
            update(id) { $0.title = info.title; $0.videoID = info.id }
            if attempt.video == nil { attempt.lookedUp(VideoDetails(id: info.id, title: info.title)) }
        case .details(let details):
            let saved = attempt.lookedUp(details)
            let planned = attempt.downloadFolder.plannedFile(
                attempt.request.namePlan(for: details), video: saved,
                fileExtension: attempt.request.expectedFileExtension, downloadAgain: attempt.downloadAgain
            )
            update(id) { $0.title = details.title; $0.videoID = details.id; $0.plannedFile = planned }
        case .file(_, let path):
            attempt.file = URL(fileURLWithPath: path)
        case .progress, .entry:
            break
        }
        update(id) { [progress = attempt.progress] in $0.state = .running(progress) }
    }

    /// yt-dlp ended: a success is moved from the incomplete folder to its Naming pattern name
    /// (the collision rule applied again against the folder as it is now) and tagged; anything
    /// else fails the row.
    private func finish(_ id: QueueItem.ID, _ attempt: inout Attempt, exit: YtDlpExit) {
        guard exit.succeeded, let downloaded = attempt.file else {
            update(id) { $0.state = .failed(DownloadFailure(termination: exit.termination, details: exit.stderr)) }
            return
        }
        if attempt.video == nil {
            // No lookup line arrived; the output's own name is the video ID (`DownloadArguments.outputTemplate`).
            attempt.lookedUp(VideoDetails(id: DownloadArguments.videoID(ofOutput: downloaded), title: attempt.request.origin.title ?? ""))
        }
        guard let (details, saved) = attempt.video else { return }
        do {
            switch try attempt.downloadFolder.place(
                downloaded, plan: attempt.request.namePlan(for: details), video: saved, downloadAgain: attempt.downloadAgain
            ) {
            case .placed(let placed):
                attempt.file = nil
                let folder = attempt.request.downloadFolder
                if savedFiles[folder]?[saved] == nil { savedFiles[folder]?[saved] = placed }
                update(id) { $0.plannedFile = placed; $0.state = .finished(file: placed) }
            case .alreadyThere(let existing):
                // Saved meanwhile (e.g. listed twice in this batch): never overwritten.
                update(id) { $0.plannedFile = existing; $0.state = .alreadyDownloaded(file: existing) }
            }
        } catch {
            update(id) { $0.state = .failed(DownloadFailure(termination: exit.termination, details: String(describing: error))) }
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
