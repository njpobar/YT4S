import SwiftUI
import YT4SCore

/// The footer's Update app button: a dot when an update is waiting, disabled with a hint while
/// downloads run, and the plain explanation when a click did not end in a relaunch.
///
/// Set `model.downloadsRunning` from the Queue to disable it.
struct UpdateAppButton: View {
    let model: AppUpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(model.title) { model.updateApp() }
                .controlSize(.small)
                .disabled(!model.isEnabled)
                .overlay(alignment: .topTrailing) {
                    if model.showsDot && !model.isUpdating {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -3)
                            .accessibilityLabel("Update available")
                    }
                }
                .help(model.showsDot ? "A new version of YT4S is ready to install" : "Check for a new version of YT4S")
            if let hint = model.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
