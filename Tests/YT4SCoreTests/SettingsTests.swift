import Foundation
import Testing
@testable import YT4SCore

/// A throwaway `UserDefaults` suite, so tests never touch the real app's settings.
final class TestDefaults {
    let suiteName = "YT4SCoreTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A fresh store over the same suite, as after a relaunch.
    func relaunch() -> Settings { Settings(defaults: defaults) }
}

@Suite struct SettingsTests {
    @Test func firstRunDefaultsAreVideoBestTitleAdvancedOffAndYT4SInDownloads() {
        let settings = TestDefaults().relaunch()

        #expect(settings.downloadFolder == MainWindowModel.defaultDownloadFolder)
        #expect(settings.options == DownloadOptions(format: .video, quality: .best, naming: .title))
        #expect(settings.advancedNaming == false)
        #expect(settings.customPattern == "")
    }

    @Test func everyChoiceSurvivesRelaunch() {
        let suite = TestDefaults()
        let settings = suite.relaunch()
        settings.downloadFolder = URL(fileURLWithPath: "/Users/sarah/Movies/YouTube", isDirectory: true)
        settings.advancedNaming = true
        settings.customPattern = "%(channel)s/%(title)s"

        let relaunched = suite.relaunch()

        #expect(relaunched.downloadFolder.path == "/Users/sarah/Movies/YouTube")
        #expect(relaunched.advancedNaming == true)
        #expect(relaunched.customPattern == "%(channel)s/%(title)s")
    }

    @Test func downloadFolderIsStoredAsAPlainPath() {
        let suite = TestDefaults()
        suite.relaunch().downloadFolder = URL(fileURLWithPath: "/Users/sarah/Movies/YouTube", isDirectory: true)

        #expect(suite.defaults.string(forKey: Settings.Key.downloadFolder) == "/Users/sarah/Movies/YouTube")
    }

    @Test func formatQualityAndNamingAreStoredUnderTheirOwnKeys() {
        let suite = TestDefaults()
        suite.relaunch().options = .default

        #expect(suite.defaults.string(forKey: Settings.Key.format) == "video")
        #expect(suite.defaults.string(forKey: Settings.Key.quality) == "best")
        #expect(suite.defaults.string(forKey: Settings.Key.naming) == "title")
    }

    @Test func unreadableValuesFallBackToDefaults() {
        let suite = TestDefaults()
        suite.defaults.set("hologram", forKey: Settings.Key.format)
        suite.defaults.set("8k", forKey: Settings.Key.quality)
        suite.defaults.set(42, forKey: Settings.Key.naming)
        suite.defaults.set("", forKey: Settings.Key.downloadFolder)

        let settings = suite.relaunch()

        #expect(settings.options == .default)
        #expect(settings.downloadFolder == MainWindowModel.defaultDownloadFolder)
    }
}
