import AppKit
import UserNotifications
import YT4SCore

/// Posts a macOS notification when a Queue batch finishes, only while YT4S is in the background.
/// In the foreground the Queue header already says it all, and the app never shows modals.
@MainActor
enum BatchNotifier {
    static func batchFinished(_ summary: QueueSummary) {
        guard !NSApplication.shared.isActive, !summary.text.isEmpty else { return }
        // UNUserNotificationCenter traps outside an app bundle (e.g. `swift run`).
        guard Bundle.main.bundleIdentifier != nil else { return }

        let body = summary.text.prefix(1).uppercased() + summary.text.dropFirst()
        Task {
            let center = UNUserNotificationCenter.current()
            // Asked the first time there is something to say; later calls return the stored answer.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Downloads finished"
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
