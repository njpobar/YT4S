import Foundation

/// Why a video failed, as one of a fixed set the user can act on (#11). Raw yt-dlp text is never
/// shown in the row; it stays behind Details.
///
/// Consumers decide behaviour per category: Retry (`isRetryable`), Network auto-retry, and the
/// Looks-outdated banner / early stop (#31), which keys off `.looksOutdated` alone.
public enum FailureCategory: Equatable, Sendable, CaseIterable {
    /// Private, removed, members-only or age-restricted. Retrying cannot help.
    case unavailable
    /// Blocked in the user's country. Retrying cannot help.
    case regionBlocked
    /// YouTube could not be reached or the connection dropped. Auto-retried once.
    case network
    /// The file could not be written: disk full, or the Download folder is not writable.
    case disk
    /// YouTube changed something the current yt-dlp does not handle (403s, extraction or nsig
    /// errors, bot-check, missing player response). Updating yt-dlp is the fix.
    case looksOutdated
    case unknown

    /// Categorizes a failed run from yt-dlp's stderr and how it ended (`nil`: it never launched).
    ///
    /// Only `ERROR:` lines are read when there are any, so a warning printed along the way (e.g.
    /// "n challenge solving failed") cannot override the error that actually stopped the run.
    /// Rules are checked in order; the first match wins.
    public init(stderr: String, termination: SubprocessTermination?) {
        guard case .exited = termination else {
            self = .unknown
            return
        }
        let errorLines = stderr.split(whereSeparator: \.isNewline).filter { $0.contains("ERROR:") }
        let text = errorLines.isEmpty ? stderr : errorLines.joined(separator: "\n")
        self = Self.rules.first { rule in rule.markers.contains { text.localizedCaseInsensitiveContains($0) } }?.category ?? .unknown
    }

    /// Order matters: yt-dlp appends "please report this issue ... yt-dlp -U" to many errors,
    /// including connection failures, so that text is never a marker; and a 403 counts as
    /// Looks outdated before any network marker can claim it.
    private static let rules: [(category: FailureCategory, markers: [String])] = [
        (.disk, [
            "No space left on device", "Errno 28", "Disk quota exceeded",
            "Read-only file system", "Errno 30", "Permission denied", "Errno 13",
            "unable to open for writing",
        ]),
        (.regionBlocked, [
            "not made this video available in your country", "not available in your country",
            "not available from your location", "geo restriction",
        ]),
        (.unavailable, [
            "Video unavailable", "This video is unavailable", "Private video",
            "has been removed", "no longer available", "members-only",
            "confirm your age", "age-restricted", "inappropriate for some users",
        ]),
        (.looksOutdated, [
            "HTTP Error 403", "not found, unable to continue", "Unable to extract", "nsig", "n challenge",
            "Signature solving failed", "signature extraction failed", "not a bot",
            "player response", "Requested format is not available",
        ]),
        (.network, [
            "timed out", "Connection refused", "Connection reset", "Connection aborted",
            "Failed to resolve", "nodename nor servname", "Name or service not known",
            "Temporary failure in name resolution", "Network is unreachable", "No route to host",
            "Unable to connect to proxy", "Remote end closed connection", "IncompleteRead",
            "internet connection appears to be offline",
        ]),
    ]

    /// Whether Retry can help. Unavailable and Region-blocked get Details only.
    public var isRetryable: Bool {
        switch self {
        case .unavailable, .regionBlocked: false
        case .network, .disk, .looksOutdated, .unknown: true
        }
    }

    /// The one plain sentence a failed row shows: cause, then what to do.
    public var sentence: String {
        switch self {
        case .unavailable:
            "This video is private, removed, members-only or age-restricted. Open it on YouTube to check."
        case .regionBlocked:
            "This video isn't available in your country, so it can't be downloaded."
        case .network:
            "Couldn't reach YouTube. Check your internet connection, then Retry."
        case .disk:
            "Couldn't save the file. Make sure the Download folder has free space and can be written to, then Retry."
        case .looksOutdated:
            "YouTube may have changed. Try Update yt-dlp below, then Retry."
        case .unknown:
            "Something went wrong. Retry, or check Details for what yt-dlp said."
        }
    }
}
