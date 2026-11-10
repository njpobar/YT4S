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
    /// Snips running, by row. They run alongside downloads, never in the worker.
    @ObservationIgnored private var snips: [QueueItem.ID: RunningSnip] = [:]
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
    /// (the files already there, original or Snipped copy, are kept). The row forgets its Snip.
    /// No effect on other states or while the row is snipping.
    public func downloadAgain(_ id: QueueItem.ID) {
        guard let item = item(id), item.isAlreadyDownloaded, !item.isSnipping else { return }
        update(id) { $0.downloadAgain = true; $0.snip = nil; $0.state = .pending }
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

    /// Stops a pending or running item and deletes its partial files, or stops a row's Snip and
    /// deletes its partial copy (the row is Done again, as before the Snip). No effect on other states.
    public func cancel(_ id: QueueItem.ID) {
        guard let item = item(id) else { return }
        if item.isSnipping {
            snips[id]?.task.cancel()
            return
        }
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
    /// Rows being snipped stay.
    public func clearFinished() {
        items.removeAll { $0.isDone && !$0.isSnipping }
        dismissOutdatedBanner()
    }

    /// The banner's X. It shows again only after new Looks-outdated failures.
    public func dismissOutdatedBanner() {
        outdated.dismissBanner()
    }

    /// Removes one row that is not waiting or running. Files on disk are never touched.
    public func remove(_ id: QueueItem.ID) {
        items.removeAll { $0.id == id && !$0.isActive && !$0.isSnipping }
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

    // MARK: - Snip

    /// What a Snip of a Done or Already downloaded row starts from: the row's file, which is the
    /// original whenever it is there (skip detection prefers it), or the Snipped copy when that
    /// is all that is left. `nil` when the row cannot be snipped now.
    public func snipSource(_ id: QueueItem.ID) -> SnipSource? {
        guard let item = item(id), item.isSnippable, let file = item.doneFile else { return nil }
        return SnipSource(file: file, isSnippedCopy: DownloadFolder(url: item.request.downloadFolder).isSnippedCopy(file))
    }

    /// Snip pressed on a row: finds its file again by its tags, wherever it was renamed or moved
    /// to inside the Download folder (the original whenever it is there, else a Snipped copy), and
    /// points the row at it. `.fileGone` when it is no longer in the Download folder; `nil` when
    /// the row cannot be snipped now.
    public func prepareSnip(_ id: QueueItem.ID) -> SnipStart? {
        guard let item = item(id), item.isSnippable, let file = item.doneFile else { return nil }
        let folder = DownloadFolder(url: item.request.downloadFolder)
        guard let video = savedVideo(of: item, in: folder),
              let found = folder.file(of: video, probablyAt: file) else { return .fileGone }
        if found != file { update(id) { $0.pointDoneFile(at: found) } }
        return snipSource(id).map(SnipStart.ready) ?? .fileGone
    }

    /// The video and Format a row's file holds: the row's own, else its file's tags.
    private func savedVideo(of item: QueueItem, in folder: DownloadFolder) -> SavedVideo? {
        item.videoID.map { SavedVideo(videoID: $0, format: item.request.options.format) }
            ?? item.doneFile.flatMap(folder.savedVideo(ofFileAt:))
    }

    /// Saves a Snipped copy of a Done or Already downloaded row's file (`snipSource`) with
    /// `plan`'s Cuts left out, next to it; that file is never changed. Runs at once, alongside any
    /// download; the row shows "Snipping N%", then "Done - snipped" (or "Already downloaded -
    /// snipped"). A Snip that fails leaves nothing behind and the row says "Couldn't save the
    /// Snipped copy" with Details; Snip is available again. No effect on other rows or while the
    /// row is already snipping.
    public func snip(_ id: QueueItem.ID, plan: SnipPlan) {
        guard let item = item(id), let source = snipSource(id) else { return }
        let folder = DownloadFolder(url: item.request.downloadFolder)
        guard let video = savedVideo(of: item, in: folder) else { return }
        // What a cancelled Snip returns the row to: its last saved Snipped copy, if any.
        let before: SnipStatus? = if case .snipped = item.snip { item.snip } else { nil }
        update(id) { $0.snip = .snipping(fraction: nil) }
        let workFolder = Snipper.newWorkFolder(in: folder)
        let snipper = Snipper(tools: runner.tools, environment: runner.environment)
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Snipping a video")
        let task = Task { [weak self] in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let progress = AsyncStream.makeStream(of: Double.self)
            // A child task, so cancelling this one stops ffmpeg; it ends only once its files are gone.
            async let copy = {
                defer { progress.continuation.finish() }
                return try await snipper.snip(
                    source, video: video, plan: plan, in: folder, workFolder: workFolder,
                    onProgress: { progress.continuation.yield($0) }
                )
            }()
            for await fraction in progress.stream {
                self?.update(id) { $0.snip = .snipping(fraction: fraction) }
            }
            let result: SnipStatus?
            do {
                result = .snipped(copy: try await copy)
            } catch let failure as SnipFailure {
                result = .failed(details: failure.details)
            } catch {
                // Cancelled: the row is Done again, as before the Snip.
                result = before
            }
            guard let self else { return }
            self.update(id) { $0.snip = result }
            self.snips[id] = nil
            // The Snip's work folder is gone; the incomplete folder too, unless a download needs it.
            if !self.items.contains(where: { $0.isActive && $0.request.downloadFolder == folder.url }) {
                folder.removeIncompleteFolderIfEmpty()
            }
        }
        snips[id] = RunningSnip(task: task, workFolder: workFolder)
    }

    /// Quitting: stops every Snip and deletes its partial copy before returning, as the app exits
    /// right after. Call it once `ChildProcesses.terminateAll` has stopped ffmpeg.
    public func stopSnipsForQuit() {
        for (id, snip) in snips {
            snip.task.cancel()
            try? FileManager.default.removeItem(at: snip.workFolder)
            // Nothing else writes there any more: downloads were stopped with ffmpeg.
            item(id).map { DownloadFolder(url: $0.request.downloadFolder).removeIncompleteFolderIfEmpty() }
        }
    }

    /// Returns once no Snip is running.
    public func waitUntilSnipsFinished() async {
        while let snip = snips.values.first {
            await snip.task.value
        }
    }

    /// A Snip in progress: what stops it, and the folder ffmpeg writes its partial copy into.
    private struct RunningSnip {
        let task: Task<Void, Never>
        let workFolder: URL
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
                // A new original wins over a Snipped copy this batch found.
                if savedFiles[folder]?[saved].map(attempt.downloadFolder.isSnippedCopy) ?? true {
                    savedFiles[folder]?[saved] = placed
                }
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
