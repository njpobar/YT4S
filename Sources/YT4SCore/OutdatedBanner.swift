import Foundation

/// The banner shown when downloads fail because YouTube changed and yt-dlp has not caught up (#11).
/// It points at the footer's Update yt-dlp button and never runs the update itself (ADR 0002).
/// When it shows is decided by the Queue (`Queue.showsOutdatedBanner`).
public enum OutdatedBanner {
    /// - Parameter updateAppliedThisSession: an Update yt-dlp installed a new copy since launch, so
    ///   failures that show the banner again came after it: Roll back is worth a try too.
    public static func text(updateAppliedThisSession: Bool) -> String {
        "YouTube may have changed. Try Update yt-dlp below."
    }
}
