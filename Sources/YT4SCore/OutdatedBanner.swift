import Foundation

/// The banner shown when downloads fail because YouTube changed and yt-dlp has not caught up (#11).
/// It points at the footer's Update yt-dlp button and never runs the update itself (ADR 0002).
/// When it shows is decided by `OutdatedBatch` (`Queue.showsOutdatedBanner`).
public enum OutdatedBanner {
    /// - Parameter updateAppliedThisSession: an Update yt-dlp installed a new copy since launch, so
    ///   failures that show the banner again came after it: Roll back is worth a try too.
    public static func text(updateAppliedThisSession: Bool) -> String {
        updateAppliedThisSession
            ? "YouTube may have changed. Try Update yt-dlp below, or Roll back if the last update made things worse."
            : "YouTube may have changed. Try Update yt-dlp below."
    }
}

/// The Looks-outdated rules (#11) over one batch: the items queued or retried since the Queue was
/// last idle. Decides when the banner shows and when the batch stops early.
struct OutdatedBatch {
    /// 2 or more videos of the batch failed as Looks outdated, or the batch was a single video
    /// that did. Stays until dismissed, across batches.
    private(set) var showsBanner = false
    private var members: Set<QueueItem.ID> = []
    private var outdatedFailures = 0
    private var consecutiveOutdatedFailures = 0

    /// Adds an item queued or retried; `startsNewBatch` when the Queue was idle.
    mutating func join(_ id: QueueItem.ID, startsNewBatch: Bool) {
        if startsNewBatch {
            members = []
            outdatedFailures = 0
            consecutiveOutdatedFailures = 0
        }
        members.insert(id)
    }

    /// The banner's X (or Clear finished, or a switched yt-dlp). It shows again only after new
    /// Looks-outdated failures.
    mutating func dismissBanner() {
        showsBanner = false
        outdatedFailures = 0
    }

    /// Counts the outcome of `item`, which just stopped running, against `items` (the whole
    /// Queue). Returns true when this makes 3 Looks-outdated failures in a row: the batch stops
    /// early and waiting videos are left Not started.
    mutating func record(_ item: QueueItem, in items: [QueueItem]) -> Bool {
        guard case .failed(let failure) = item.state, failure.category == .looksOutdated else {
            consecutiveOutdatedFailures = 0
            return false
        }
        outdatedFailures += 1
        consecutiveOutdatedFailures += 1
        if outdatedFailures >= 2 || videosRun(in: items) == 1 { showsBanner = true }
        return consecutiveOutdatedFailures >= 3
    }

    /// Batch items yt-dlp was asked to download: Already downloaded ones were skipped.
    private func videosRun(in items: [QueueItem]) -> Int {
        items.count { members.contains($0.id) && !$0.isAlreadyDownloaded }
    }
}

extension Queue {
    /// Dismisses the banner whenever Update yt-dlp installs a new copy or Roll back switches copies:
    /// the next downloads run with a different yt-dlp. Takes over `ytDlp.onSwitched`.
    public func dismissesOutdatedBanner(whenSwitching ytDlp: YtDlpUpdateModel) {
        ytDlp.onSwitched = { [weak self] in self?.dismissOutdatedBanner() }
    }
}
