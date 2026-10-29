import Sparkle
import SwiftUI
import YT4SCore

@main
struct YT4SApp: App {
    // Created but not started: the Update app slice adds SUFeedURL / SUPublicEDKey and starts it.
    // Holding it here keeps Sparkle linked and loaded from Contents/Frameworks from day one.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // Created once with the App. Not @State: on the macOS 27 SDK @State is a SwiftUI macro whose
    // plugin ships only with Xcode, and this project builds with Command Line Tools.
    private let model = MainWindowModel(
        queue: Queue(runner: YtDlpRunner(tools: BundledTools(resourcesDirectory: Bundle.main.resourceURL!)))
    )

    init() {
        model.queue.onBatchFinished = { BatchNotifier.batchFinished($0) }
    }

    var body: some Scene {
        Window("YT4S", id: "main") {
            MainWindow(model: model)
        }
        .defaultSize(width: 640, height: 760)
        .windowResizability(.contentMinSize)
    }
}
