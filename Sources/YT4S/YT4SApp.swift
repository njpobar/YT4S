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
    }

    init() {
        model.queue.onBatchFinished = { BatchNotifier.batchFinished($0) }
    }

    var body: some Scene {
        Window("YT4S", id: "main") {
            if let models {
                MainWindow(model: models.window, ytDlpUpdates: models.ytDlpUpdates, appUpdate: models.appUpdate)
            } else {
                MoveToApplicationsView(location: installLocation)
            }
        }
        .defaultSize(width: 640, height: 760)
        .windowResizability(.contentMinSize)
    }
}
