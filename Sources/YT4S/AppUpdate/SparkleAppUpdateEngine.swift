import AppKit
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
            NSLog("YT4S: app updates are off: %@", error.localizedDescription)
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

    private func finishInstall(_ event: AppUpdateEvent) {
        guard installing else { return }
        installing = false
        onEvent?(event)
    }
}

// MARK: - Background probe results

extension SparkleAppUpdateEngine: @preconcurrency SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard !installing else { return }
        onEvent?(.found(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        guard !installing else { return }
        onEvent?(.upToDate)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        guard !installing else { return }
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) { return }
        onEvent?(.failed(AppUpdateFailure(sparkleError: error)))
    }
}

// MARK: - A silent user driver: every answer is "install now"

extension SparkleAppUpdateEngine: @preconcurrency SPUUserDriver {
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
        NSLog("YT4S: app update failed: %@", String(describing: error))
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
