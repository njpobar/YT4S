import Foundation

/// The banner shown when downloads fail because YouTube changed and yt-dlp has not caught up (#11).
/// It points at the footer's Update yt-dlp button and never runs the update itself (ADR 0002).
/// When it shows is decided by the Queue (`Queue.showsOutdatedBanner`).
public enum OutdatedBanner {
    /// - Parameter updateAppliedThisSession: an Update yt-dlp installed a new copy since launch, so
    ///   failures that show the banner again came after it: Roll back is worth a try too.
    public static func text(updateAppliedThisSession: Bool) -> String {
        updateAppliedThisSession
            ? "YouTube may have changed. Try Update yt-dlp below, or Roll back if the last update made things worse."
            : "YouTube may have changed. Try Update yt-dlp below."
    }
}

extension Queue {
    /// Dismisses the banner whenever Update yt-dlp installs a new copy or Roll back switches copies:
    /// the next downloads run with a different yt-dlp. Takes over `ytDlp.onSwitched`.
    public func dismissesOutdatedBanner(whenSwitching ytDlp: YtDlpUpdateModel) {
        ytDlp.onSwitched = { [weak self] in self?.dismissOutdatedBanner() }
    }
}
