import Foundation
import Observation

/// What the app updater (Sparkle, in the app) tells the model.
public enum AppUpdateEvent: Sendable, Equatable {
    /// A newer version is in the appcast.
    case found(version: String)
    /// The appcast has nothing newer than the running version.
    case upToDate
    /// The check or the install stopped; nothing was installed.
    case failed(AppUpdateFailure)
}

/// The boundary to the real updater. The app adapts Sparkle to this; tests fake it.
@MainActor public protocol AppUpdateEngine: AnyObject {
    var onEvent: (@MainActor (AppUpdateEvent) -> Void)? { get set }
    /// Look for an update without downloading or showing anything.
    func checkInBackground()
    /// Look for an update and, if there is one, download, verify, install and relaunch, without
    /// prompts. Reports `.upToDate` or `.failed` if it does not end in a relaunch.
    func install()
}

/// Footer hints shared by the Update app and Update yt-dlp buttons.
public enum UpdateButtonHint {
    /// Both update buttons are disabled while any download runs (ADR 0002).
    public static let downloadsRunning = "Finish or cancel the Queue first."
}

/// State behind the footer's Update app button (ADR 0002): checks on launch and daily, shows a
/// dot when an update is found, and installs only when clicked.
@MainActor @Observable public final class AppUpdateModel {
    public typealias Sleep = @MainActor @Sendable (Duration) async throws -> Void

    /// How often to check again while the app is left open.
    public static let checkInterval = Duration.seconds(24 * 60 * 60)

    /// An update was found; the button shows a dot. Nothing is downloaded until a click.
    public private(set) var showsDot = false
    /// Sparkle is downloading and installing; it quits and relaunches the app when done.
    public private(set) var isUpdating = false
    /// Footer text after a click that did not relaunch: up to date, or what failed.
    public private(set) var message: String?

    /// Set by the app from the Queue: true while any download runs.
    public var downloadsRunning = false

    public var isEnabled: Bool { !downloadsRunning && !isUpdating }
    public var title: String { isUpdating ? "Updating…" : "Update app" }
    /// Why the button is disabled, shown next to it.
    public var hint: String? { downloadsRunning && !isUpdating ? UpdateButtonHint.downloadsRunning : nil }

    private let engine: AppUpdateEngine
    private let currentVersion: String
    private let sleep: Sleep
    private var schedule: Task<Void, Never>?

    public init(
        engine: AppUpdateEngine,
        currentVersion: String,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        self.currentVersion = currentVersion
        self.sleep = sleep
        engine.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Checks now (app launch), then once a day until `stop()`.
    public func start() {
        checkInBackground()
        schedule?.cancel()
        schedule = Task { [weak self, sleep] in
            while true {
                do { try await sleep(Self.checkInterval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.checkInBackground()
            }
        }
    }

    public func stop() {
        schedule?.cancel()
        schedule = nil
    }

    /// The button's action: install the update found (or look for one) without prompts.
    public func updateApp() {
        guard isEnabled else { return }
        message = nil
        isUpdating = true
        engine.install()
    }

    private func checkInBackground() {
        guard !isUpdating else { return }
        engine.checkInBackground()
    }

    private func handle(_ event: AppUpdateEvent) {
        let clicked = isUpdating
        isUpdating = false
        switch event {
        case .found:
            showsDot = true
        case .upToDate:
            showsDot = false
            if clicked { message = "YT4S \(currentVersion) is up to date." }
        case .failed(let failure):
            // A failed background check stays quiet; the next one tries again.
            if clicked { message = failure.message(currentVersion: currentVersion) }
        }
    }
}
