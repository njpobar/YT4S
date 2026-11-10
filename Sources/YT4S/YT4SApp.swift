import SwiftUI
import YT4SCore

@main
struct YT4SApp: App {
    private let installLocation = InstallLocation.current()

    // Created once with the App. Not @State: on the macOS 27 SDK @State is a SwiftUI macro whose
    // plugin ships only with Xcode, and this project builds with Command Line Tools.
    // Nil when YT4S must first be moved to /Applications: Sparkle cannot update it from anywhere else.
    private let models: WindowModels?

    init() {
        models = installLocation.mustMove ? nil : Self.makeModels()
        models?.window.queue.onBatchFinished = { BatchNotifier.batchFinished($0) }
        // Quitting mid-download: stop yt-dlp, its ffmpeg and any listing instead of leaving them
        // running without the app. The next launch removes their unfinished files. A Snip's
        // partial copy is deleted now. Posted on the main thread.
        let queue = models?.window.queue
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ChildProcesses.all.terminateAll()
            MainActor.assumeIsolated { queue?.stopSnipsForQuit() }
        }
    }

    var body: some Scene {
        Window("YT4S", id: "main") {
            if let models {
                MainWindowContent(models: models)
            } else {
                MoveToApplicationsView(location: installLocation)
            }
        }
        .defaultSize(width: 640, height: 760)
        .windowResizability(.contentMinSize)

        // One Snip window per Queue row, opened by its Snip button only (no File > New).
        WindowGroup("Snip", id: SnipWindow.id, for: QueueItem.ID.self) { $itemID in
            if let models {
                SnipWindow(queue: models.window.queue, itemID: itemID)
            }
        }
        .defaultSize(width: 820, height: 600)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }
}
