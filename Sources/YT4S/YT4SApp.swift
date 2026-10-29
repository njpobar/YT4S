import SwiftUI
import YT4SCore

@main
struct YT4SApp: App {
    private let installLocation = InstallLocation.current()

    // Created once with the App (not @State: that macro's plugin ships only with Xcode). Nil when
    // YT4S must first be moved to /Applications: Sparkle cannot update it from anywhere else.
    private let appUpdate: AppUpdateModel?

    init() {
        if installLocation.mustMove {
            appUpdate = nil
        } else {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let appUpdate = AppUpdateModel(engine: SparkleAppUpdateEngine(), currentVersion: version)
            appUpdate.start()
            self.appUpdate = appUpdate
        }
    }

    var body: some Scene {
        Window("YT4S", id: "main") {
            if let appUpdate {
                MainWindow()
                    // Placeholder until the footer row (Update yt-dlp, Roll back, Update app) lands.
                    .safeAreaInset(edge: .bottom, alignment: .leading) {
                        UpdateAppButton(model: appUpdate).padding(12)
                    }
            } else {
                MoveToApplicationsView(location: installLocation)
            }
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
