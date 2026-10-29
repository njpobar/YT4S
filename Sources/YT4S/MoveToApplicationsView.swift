import AppKit
import SwiftUI
import YT4SCore

/// Shown instead of the main window when YT4S runs from anywhere but /Applications (the DMG,
/// Downloads, an App Translocation copy): self-update would fail there (ADR 0002).
struct MoveToApplicationsView: View {
    let location: InstallLocation

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Move YT4S to Applications")
                .font(.title2.weight(.semibold))
            Text("YT4S only works from your Applications folder, so it can update itself.\nQuit YT4S, drag it into Applications, then open it from there.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Open Applications Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: InstallLocation.applicationsFolder))
                }
                Button("Quit YT4S") { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(minWidth: 560, minHeight: 640)
    }
}
