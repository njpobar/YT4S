import Sparkle
import SwiftUI

@main
struct YT4SApp: App {
    // Created but not started: the Update app slice adds SUFeedURL / SUPublicEDKey and starts it.
    // Holding it here keeps Sparkle linked and loaded from Contents/Frameworks from day one.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        Window("YT4S", id: "main") {
            MainWindow()
        }
        .defaultSize(width: 640, height: 760)
        .windowResizability(.contentMinSize)
    }
}

/// The one-column main window. Empty until the paste box, Queue and footer slices land.
struct MainWindow: View {
    var body: some View {
        Color.clear
            .frame(minWidth: 560, minHeight: 640)
    }
}
