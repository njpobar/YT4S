import Foundation

/// Where YT4S.app is running from, and whether it must be moved to /Applications first.
///
/// Self-update swaps the bundle in place, so it needs a stable, writable location.
/// Anywhere else (Downloads, the DMG, an App Translocation copy) breaks it (ADR 0002).
public struct InstallLocation: Sendable, Equatable {
    /// UserDefaults key (also settable as a launch argument, `-YT4SAllowAnyLocation YES`)
    /// that lets a development build run from `build/`.
    public static let allowAnyLocationKey = "YT4SAllowAnyLocation"

    public static let applicationsFolder = "/Applications"

    public let bundlePath: String
    public let mustMove: Bool

    public init(bundlePath: String, allowAnyLocation: Bool = false) {
        self.bundlePath = bundlePath
        let path = (bundlePath as NSString).standardizingPath
        let isAppBundle = path.hasSuffix(".app")
        let parent = (path as NSString).deletingLastPathComponent
        mustMove = isAppBundle && !allowAnyLocation && parent != Self.applicationsFolder
    }

    /// The running app's location, honouring the development override in `defaults`.
    public static func current(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> InstallLocation {
        InstallLocation(
            bundlePath: bundle.bundleURL.resolvingSymlinksInPath().path,
            allowAnyLocation: defaults.bool(forKey: allowAnyLocationKey)
        )
    }
}
