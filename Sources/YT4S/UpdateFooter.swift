import SwiftUI
import YT4SCore

/// The quiet footer row at the bottom of the main window (prototype `.upd`): yt-dlp version and
/// Update yt-dlp and Roll back, then YT4S version and Update app, each update button with a dot
/// badge when an update is available; below it the footer status / error text.
struct UpdateFooter: View {
    let ytDlp: YtDlpUpdateModel
    let app: AppUpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                YtDlpUpdateControls(model: ytDlp)
                Spacer().frame(width: 10)
                AppUpdateControls(model: app)
                Spacer(minLength: 0)
            }
            ForEach(statusLines, id: \.self) { line in
                Text(line.text)
                    .foregroundStyle(line.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private struct StatusLine: Hashable {
        var text: String
        var isError: Bool
    }

    /// Both buttons share one "finish the Queue" hint; then what each update last said.
    private var statusLines: [StatusLine] {
        var lines: [StatusLine] = []
        if let hint = ytDlp.hint ?? app.hint {
            lines.append(StatusLine(text: hint, isError: false))
        }
        if let message = ytDlp.message {
            lines.append(StatusLine(text: message.text, isError: message.isError))
        }
        if let message = app.message {
            lines.append(StatusLine(text: message, isError: false))
        }
        return lines
    }
}

private struct YtDlpUpdateControls: View {
    let model: YtDlpUpdateModel

    var body: some View {
        Text(model.versionLabel)
            .monospacedDigit()
        UpdateButton(title: "Update yt-dlp", showsBadge: model.showsBadge, help: helpText) {
            Task { await model.update() }
        }
        .disabled(!model.canUpdate)
        Button("Roll back") { model.rollBack() }
            .controlSize(.small)
            .disabled(!model.canRollBack)
            .help(rollBackHelp)
    }

    private var rollBackHelp: String {
        guard let target = model.rollBackTarget else {
            return "Nothing to roll back to. Roll back becomes available after Update yt-dlp installs a new version."
        }
        let version = target.version.map { "yt-dlp \($0.tag)" } ?? "the yt-dlp that came with YT4S"
        return "Go back to \(version) if the new one works worse. Works offline."
    }

    private var helpText: String {
        if let version = model.available {
            return "yt-dlp \(version.tag) is available. Click to download and install it."
        }
        return "Check for a newer yt-dlp and install it."
    }
}

private struct AppUpdateControls: View {
    let model: AppUpdateModel

    var body: some View {
        Text(model.versionLabel)
            .monospacedDigit()
        UpdateButton(
            title: model.title,
            showsBadge: model.showsDot && !model.isUpdating,
            help: model.showsDot ? "A new version of YT4S is ready to install." : "Check for a new version of YT4S."
        ) {
            model.updateApp()
        }
        .disabled(!model.isEnabled)
    }
}

/// A small footer button with the dot badge after its title when an update is available.
private struct UpdateButton: View {
    let title: String
    let showsBadge: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if showsBadge {
                    UpdateBadge()
                }
            }
        }
        .controlSize(.small)
        .help(help)
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

/// The main window's models.
struct WindowModels {
    let window: MainWindowModel
    let ytDlpUpdates: YtDlpUpdateModel
    let appUpdate: AppUpdateModel
}

extension YT4SApp {
    /// The window's models, wired so downloads run the yt-dlp copy the updater selected and both
    /// updaters know when the Queue is busy. Starts the launch checks.
    @MainActor
    static func makeModels() -> WindowModels {
        let resources = Bundle.main.resourceURL!
        let installations = YtDlpInstallations(
            root: YtDlpInstallations.defaultRoot(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.njpobar.YT4S"),
            bundled: BundledYtDlp(resourcesDirectory: resources)
        )
        // The Queue is created after the yt-dlp update model (it needs its selection), so this is read lazily.
        let queueBox = QueueBox()
        let downloadsRunning: @MainActor () -> Bool = { queueBox.queue?.hasActiveDownloads ?? false }
        let ytDlpUpdates = YtDlpUpdateModel(
            updater: YtDlpUpdater(installations: installations, http: URLSessionHTTPClient()),
            downloadsRunning: downloadsRunning
        )
        let queue = Queue(runner: YtDlpRunner(tools: BundledTools(resourcesDirectory: resources), selection: ytDlpUpdates.selection))
        queueBox.queue = queue
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let appUpdate = AppUpdateModel(
            engine: SparkleAppUpdateEngine(),
            currentVersion: version,
            downloadsRunning: downloadsRunning
        )
        Task { await ytDlpUpdates.launch() }
        appUpdate.start()
        return WindowModels(
            window: MainWindowModel(queue: queue, settings: Settings(defaults: .standard)),
            ytDlpUpdates: ytDlpUpdates,
            appUpdate: appUpdate
        )
    }
}

@MainActor
private final class QueueBox {
    var queue: Queue?
}
