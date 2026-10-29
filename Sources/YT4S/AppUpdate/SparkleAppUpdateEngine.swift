import AppKit
import os
import Sparkle
import YT4SCore

/// Adapts Sparkle 2 to `AppUpdateEngine`, with no Sparkle UI at all.
///
/// - `checkInBackground()` is `checkForUpdateInformation()`: it only probes the appcast and reports
///   through the delegate.
/// - `install()` is a user-initiated `checkForUpdates()` whose user driver answers every question
///   with "install": no update prompt, no release notes, no "relaunch now?" alert. Sparkle then
///   verifies the EdDSA signature, swaps the bundle, and relaunches.
@MainActor final class SparkleAppUpdateEngine: NSObject, AppUpdateEngine {
    private static let log = Logger(subsystem: "com.njpobar.YT4S", category: "AppUpdate")

    var onEvent: (@MainActor (AppUpdateEvent) -> Void)?

    private var updater: SPUUpdater?
    /// True between `install()` and its outcome; delegate callbacks then belong to the install.
    private var installing = false

    override init() {
        super.init()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            // Fails without SUPublicEDKey (a dev build with no key configured): updates stay off.
            try updater.start()
            self.updater = updater
        } catch {
            Self.log.error("App updates are off: \(Self.describe(error), privacy: .public)")
        }
    }

    func checkInBackground() {
        guard let updater, !installing else { return }
        updater.checkForUpdateInformation()
    }

    func install() {
        guard let updater else {
            onEvent?(.failed(.other))
            return
        }
        installing = true
        updater.checkForUpdates()
    }

    /// "domain code: message", then the same for each underlying error.
    private static func describe(_ error: any Error) -> String {
        var parts: [String] = []
        var next: NSError? = error as NSError
        while let error = next {
            parts.append("\(error.domain) \(error.code): \(error.localizedDescription)")
            next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " <- ")
    }

    private func finishInstall(_ event: AppUpdateEvent) {
        guard installing else { return }
        installing = false
        onEvent?(event)
    }
}

// MARK: - Background probe results

extension SparkleAppUpdateEngine: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard !installing else { return }
        onEvent?(.found(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        guard !installing else { return }
        onEvent?(.upToDate)
    }

    /// Only background probes report failures here; an install's failure comes through
    /// `showUpdaterError` (this callback also fires after it, for the same error).
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard updateCheck == .updateInformation, let error = error as NSError? else { return }
        if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) { return }
        Self.log.notice("Background update check failed: \(Self.describe(error), privacy: .public)")
        onEvent?(.failed(AppUpdateFailure(sparkleError: error)))
    }
}

// MARK: - A silent user driver: every answer is "install now"

extension SparkleAppUpdateEngine: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // The app schedules its own checks (launch and daily); Sparkle's scheduler stays off.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(installing ? .install : .dismiss)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        finishInstall(.upToDate)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        Self.log.error("App update failed: \(Self.describe(error), privacy: .public)")
        acknowledgement()
        finishInstall(.failed(AppUpdateFailure(sparkleError: error)))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {}
}
