import AppKit
import SwiftUI
import YT4SCore

/// The main window's content: the normal window, or the damaged screen when no yt-dlp copy
/// starts (active, previous and bundled all failed, at launch or mid-session, ADR 0002).
struct MainWindowContent: View {
    let models: WindowModels

    var body: some View {
        if models.ytDlpUpdates.isDamaged {
            DamagedAppView(appUpdate: models.appUpdate)
        } else {
            MainWindow(model: models.window, ytDlpUpdates: models.ytDlpUpdates, appUpdate: models.appUpdate)
        }
    }
}

/// Blocking in-window screen: YT4S cannot download anything, so the only ways out are an app
/// update (which brings a fresh bundled yt-dlp) or a reinstall.
struct DamagedAppView: View {
    let appUpdate: AppUpdateModel

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("YT4S is damaged. Reinstall the app.")
                .font(.title2.weight(.semibold))
            Text("YT4S can't start its downloader. Update the app, or download YT4S again and drag it into Applications.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(appUpdate.title) { appUpdate.updateApp() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!appUpdate.isEnabled)
                Button("Quit YT4S") { NSApp.terminate(nil) }
            }
            if let message = appUpdate.message {
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(32)
        .frame(minWidth: 560, minHeight: 640)
    }
}
