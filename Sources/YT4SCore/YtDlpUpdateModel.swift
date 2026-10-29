import Foundation
import Observation

/// State and actions behind the footer's yt-dlp row: version, Update yt-dlp button with its badge,
/// and the footer status / error text (ADR 0002).
///
/// Checks the nightly channel at launch and then every `checkInterval` while the app is open; a
/// found update only shows the badge. Nothing is installed until `update()` (the button click).
@MainActor @Observable
public final class YtDlpUpdateModel {
    public struct Message: Equatable, Sendable {
        public var text: String
        public var isError: Bool

        public init(text: String, isError: Bool) {
            self.text = text
            self.isError = isError
        }
    }

    /// The copy downloads run with; hand it to `YtDlpRunner(selection:)`.
    public let selection: YtDlpSelection
    /// The copy in use, mirrored from `selection` for observation.
    public private(set) var current: YtDlpCopy
    /// A newer nightly found by the last check, not installed yet.
    public private(set) var available: YtDlpVersion?
    public private(set) var isUpdating = false
    /// Outcome of the last click on Update yt-dlp.
    private var result: Message?

    @ObservationIgnored private let updater: YtDlpUpdater
    @ObservationIgnored private let checkInterval: Duration
    @ObservationIgnored private let downloadsRunning: @MainActor () -> Bool
    @ObservationIgnored private var periodicCheck: Task<Void, Never>?

    /// - Parameter downloadsRunning: whether any Queue item is pending or running; read on every
    ///   access, so pass a closure over observable state (e.g. `queue.hasActiveDownloads`).
    public init(
        updater: YtDlpUpdater,
        checkInterval: Duration = .seconds(24 * 60 * 60),
        downloadsRunning: @escaping @MainActor () -> Bool
    ) {
        self.updater = updater
        self.checkInterval = checkInterval
        self.downloadsRunning = downloadsRunning
        let copy = updater.installations.current()
        self.current = copy
        self.selection = YtDlpSelection(copy)
    }

    // MARK: What the footer shows

    public var versionLabel: String { "yt-dlp \(current.version?.tag ?? "(unknown version)")" }

    public var showsBadge: Bool { available != nil }

    public var canUpdate: Bool { !isUpdating && !downloadsRunning() }

    /// The footer status / error text, or `nil` for none.
    public var message: Message? {
        if isUpdating { return Message(text: "Updating yt-dlp...", isError: false) }
        if downloadsRunning() { return Message(text: "Finish or cancel the Queue to update yt-dlp.", isError: false) }
        return result
    }

    // MARK: Actions

    /// At launch: uses the newer of the downloaded active and bundled copies, prunes downloaded
    /// copies older than the bundled one, checks for an update, then keeps checking periodically.
    public func launch() async {
        select((try? updater.installations.prepareAtLaunch()) ?? updater.installations.current())
        await check()
        periodicCheck?.cancel()
        let interval = checkInterval
        periodicCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.check()
            }
        }
    }

    /// Stops the periodic check.
    public func stop() {
        periodicCheck?.cancel()
        periodicCheck = nil
    }

    /// Looks for a newer nightly; only updates the badge. Failures are silent: the next check or
    /// a click on Update yt-dlp reports problems.
    public func check() async {
        guard !isUpdating else { return }
        do {
            available = try await updater.check()
        } catch {
            // Keep whatever the last successful check found.
        }
    }

    /// The Update yt-dlp button. Does nothing while a download runs or an update is in progress.
    public func update() async {
        guard canUpdate else { return }
        isUpdating = true
        result = nil
        defer { isUpdating = false }
        do {
            switch try await updater.update() {
            case .installed(let copy):
                select(copy)
                available = nil
                result = Message(text: "Updated to yt-dlp \(copy.version?.tag ?? "").", isError: false)
            case .upToDate(let copy):
                available = nil
                result = Message(text: "yt-dlp \(copy.version?.tag ?? "") is the latest.", isError: false)
            }
        } catch {
            let failure = error as? YtDlpUpdateError ?? .installFailed
            result = Message(text: failure.explanation(current: current.version?.tag ?? "(unknown version)"), isError: true)
        }
    }

    private func select(_ copy: YtDlpCopy) {
        selection.select(copy)
        current = copy
    }
}

extension Queue {
    /// Whether any item is pending or running: Update yt-dlp is disabled meanwhile.
    /// Derived from `items`, so it is observable.
    public var hasActiveDownloads: Bool {
        items.contains {
            switch $0.state {
            case .pending, .running: true
            case .finished, .failed: false
            }
        }
    }
}
