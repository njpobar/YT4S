import SwiftUI
import YT4SCore

/// The quiet footer row at the bottom of the main window (prototype `.upd`): yt-dlp version and
/// Update yt-dlp with its dot badge, then the footer status / error text.
/// Roll back (#30) joins the yt-dlp controls; Update app (#29) goes on the right.
struct UpdateFooter: View {
    let ytDlp: YtDlpUpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                YtDlpUpdateControls(model: ytDlp)
                Spacer(minLength: 0)
            }
            if let message = ytDlp.message {
                Text(message.text)
                    .foregroundStyle(message.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct YtDlpUpdateControls: View {
    let model: YtDlpUpdateModel

    var body: some View {
        Text(model.versionLabel)
            .monospacedDigit()
        Button {
            Task { await model.update() }
        } label: {
            HStack(spacing: 5) {
                Text("Update yt-dlp")
                if model.showsBadge {
                    UpdateBadge()
                }
            }
        }
        .controlSize(.small)
        .disabled(!model.canUpdate)
        .help(helpText)
    }

    private var helpText: String {
        if let version = model.available {
            return "yt-dlp \(version.tag) is available. Click to download and install it."
        }
        return "Check for a newer yt-dlp and install it."
    }
}

/// The dot shown on an update button when an update is available.
struct UpdateBadge: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Update available")
    }
}

extension YT4SApp {
    /// The window's models, wired so downloads run the yt-dlp copy the updater selected and the
    /// updater knows when the Queue is busy. Starts the launch check.
    @MainActor
    static func makeModels() -> (MainWindowModel, YtDlpUpdateModel) {
        let resources = Bundle.main.resourceURL!
        let installations = YtDlpInstallations(
            root: YtDlpInstallations.defaultRoot(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.njpobar.YT4S"),
            bundled: BundledYtDlp(resourcesDirectory: resources)
        )
        // The Queue is created after the update model (it needs its selection), so this is read lazily.
        let queueBox = QueueBox()
        let updates = YtDlpUpdateModel(
            updater: YtDlpUpdater(installations: installations, http: URLSessionHTTPClient()),
            downloadsRunning: { queueBox.queue?.hasActiveDownloads ?? false }
        )
        let queue = Queue(runner: YtDlpRunner(tools: BundledTools(resourcesDirectory: resources), selection: updates.selection))
        queueBox.queue = queue
        Task { await updates.launch() }
        return (MainWindowModel(queue: queue, settings: Settings(defaults: .standard)), updates)
    }
}

@MainActor
private final class QueueBox {
    var queue: Queue?
}
