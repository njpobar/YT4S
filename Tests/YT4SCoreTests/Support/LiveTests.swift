import Foundation
import Testing
@testable import YT4SCore

/// The one switch for every live test (real yt-dlp / ffmpeg, YouTube, GitHub; needs network).
/// `YT4S_LIVE_APP` names a built `YT4S.app` (e.g. `build/YT4S.app` from `scripts/build-app.sh`),
/// whose bundled tools the live tests run. Unset or empty: live tests are skipped, so a plain
/// `swift test` never touches the network.
///
///     scripts/build-app.sh && YT4S_LIVE_APP=build/YT4S.app swift test --filter Live
enum LiveTests {
    static let variable = "YT4S_LIVE_APP"

    static var app: URL? {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static var enabled: Bool { app != nil }

    /// The live app's bundled tools (`Contents/Resources/bin`).
    static var tools: BundledTools? {
        app.map { BundledTools(resourcesDirectory: $0.appendingPathComponent("Contents/Resources", isDirectory: true)) }
    }
}

extension Trait where Self == ConditionTrait {
    /// Runs the suite only when `YT4S_LIVE_APP` is set (see `LiveTests`).
    static var live: Self {
        .enabled(if: LiveTests.enabled, "set \(LiveTests.variable) to a built YT4S.app to run live tests")
    }
}
