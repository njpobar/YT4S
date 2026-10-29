import Foundation

/// The user's choices that survive relaunch, stored in `UserDefaults`.
///
/// Persisted: Download folder (plain path), Format, Quality preset, Naming pattern preset,
/// advanced toggle, custom pattern text. Not persisted: paste box, Queue.
/// Missing or unreadable values fall back to the first-run defaults (Video, Best, Title,
/// advanced off, `~/Downloads/YT4S`).
public final class Settings {
    /// The `UserDefaults` keys. Stable: changing one loses the user's saved choice.
    public enum Key {
        public static let downloadFolder = "downloadFolder"
        public static let format = "format"
        public static let quality = "quality"
        public static let naming = "naming"
        public static let advancedNaming = "advancedNaming"
        public static let customPattern = "customPattern"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var downloadFolder: URL {
        get {
            guard let path = defaults.string(forKey: Key.downloadFolder), !path.isEmpty else {
                return MainWindowModel.defaultDownloadFolder
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Key.downloadFolder) }
    }

    /// Format, Quality preset, Naming pattern and custom pattern text, each under its own key.
    public var options: DownloadOptions {
        get {
            DownloadOptions(
                format: value(Key.format) ?? DownloadOptions.default.format,
                quality: value(Key.quality) ?? DownloadOptions.default.quality,
                naming: value(Key.naming) ?? DownloadOptions.default.naming,
                customTemplate: customPattern
            )
        }
        set {
            defaults.set(newValue.format.rawValue, forKey: Key.format)
            defaults.set(newValue.quality.rawValue, forKey: Key.quality)
            defaults.set(newValue.naming.rawValue, forKey: Key.naming)
            customPattern = newValue.customTemplate
        }
    }

    /// Whether the Naming pattern row shows the custom yt-dlp template field.
    public var advancedNaming: Bool {
        get { defaults.bool(forKey: Key.advancedNaming) }
        set { defaults.set(newValue, forKey: Key.advancedNaming) }
    }

    /// The custom Naming pattern text (a yt-dlp output template). Empty until the user writes one.
    public var customPattern: String {
        get { defaults.string(forKey: Key.customPattern) ?? "" }
        set { defaults.set(newValue, forKey: Key.customPattern) }
    }

    private func value<T: RawRepresentable>(_ key: String) -> T? where T.RawValue == String {
        defaults.string(forKey: key).flatMap(T.init(rawValue:))
    }
}
