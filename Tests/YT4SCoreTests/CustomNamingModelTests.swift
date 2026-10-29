import Foundation
import Testing
@testable import YT4SCore

/// The custom Naming pattern in the main window: the advanced toggle, the template text, its
/// live preview and Download. The preview renderer is stubbed; `CustomNamePreviewTests` covers
/// the real one.
@MainActor @Suite struct CustomNamingModelTests {
    /// Records what was rendered and answers `invalid` for templates containing "bad".
    final class StubRenderer: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }

        func render(_ template: String, _ format: Format) async -> CustomNamePreview {
            lock.withLock { _calls.append(template) }
            return template.contains("bad") ? .invalid("Invalid pattern: bad") : .example("\(template).\(format.rawValue)")
        }
    }

    private func model(_ fake: FakeYtDlp, settings: Settings, renderer: StubRenderer = StubRenderer()) -> MainWindowModel {
        MainWindowModel(
            queue: Queue(runner: fake.runner(scenario: "success")), settings: settings,
            renderCustomName: { await renderer.render($0, $1) }
        )
    }

    @Test func customIsOnlyOfferedBehindTheAdvancedToggle() throws {
        let model = model(try FakeYtDlp(), settings: TestDefaults().relaunch())
        #expect(!model.advancedNaming)
        #expect(model.namingChoices == [.title, .channelTitle, .dateTitle])

        model.advancedNaming = true

        #expect(model.namingChoices == [.title, .channelTitle, .dateTitle, .custom])
    }

    @Test func theToggleCustomChoiceAndTemplateSurviveRelaunch() throws {
        let fake = try FakeYtDlp()
        let suite = TestDefaults()
        let model = model(fake, settings: suite.relaunch())

        model.advancedNaming = true
        model.options.naming = .custom
        model.options.customPattern = "%(uploader)s/%(title)s"

        let relaunched = self.model(fake, settings: suite.relaunch())
        #expect(relaunched.advancedNaming)
        #expect(relaunched.options.naming == .custom)
        #expect(relaunched.options.customPattern == "%(uploader)s/%(title)s")
        #expect(suite.defaults.string(forKey: Settings.Key.customPattern) == "%(uploader)s/%(title)s")
    }

    @Test func turningTheToggleOffGoesBackToTitleButKeepsTheTemplate() throws {
        let fake = try FakeYtDlp()
        let suite = TestDefaults()
        let model = model(fake, settings: suite.relaunch())
        model.advancedNaming = true
        model.options.naming = .custom
        model.options.customPattern = "%(title)s"

        model.advancedNaming = false

        #expect(model.options.naming == .title)
        #expect(model.options.customPattern == "%(title)s")
        #expect(self.model(fake, settings: suite.relaunch()).options.naming == .title)
    }

    @Test func customSavedWithTheToggleOffLoadsAsTitle() throws {
        let suite = TestDefaults()
        let settings = suite.relaunch()
        settings.options = DownloadOptions(format: .video, quality: .best, naming: .custom, customPattern: "%(title)s")

        #expect(model(try FakeYtDlp(), settings: suite.relaunch()).options.naming == .title)
    }

    @Test func choosingCustomStartsFromAStarterTemplate() throws {
        let model = model(try FakeYtDlp(), settings: TestDefaults().relaunch())
        model.advancedNaming = true

        model.options.naming = .custom

        #expect(model.options.customPattern == "%(channel)s/%(title)s")
    }

    @Test func thePreviewFollowsTheTemplateAndFormatAsTheyChange() async throws {
        let renderer = StubRenderer()
        let model = model(try FakeYtDlp(), settings: TestDefaults().relaunch(), renderer: renderer)
        #expect(model.customPreview == nil)
        model.advancedNaming = true
        model.options.naming = .custom
        model.options.customPattern = "a"
        model.options.customPattern = "ab"
        await model.waitForCustomPreview()
        #expect(model.customPreview == .example("ab.video"))

        model.options.format = .mp3
        await model.waitForCustomPreview()
        #expect(model.customPreview == .example("ab.mp3"))

        model.options.customPattern = "bad"
        await model.waitForCustomPreview()
        #expect(model.customPreview == .invalid("Invalid pattern: bad"))
        // Typing quickly renders only what the user paused on.
        #expect(!renderer.calls.contains("a"))
    }

    @Test func anInvalidTemplateBlocksDownloadWithItsReason() async throws {
        let model = model(try FakeYtDlp(), settings: TestDefaults().relaunch())
        model.advancedNaming = true
        model.options.naming = .custom
        model.options.customPattern = "bad"
        await model.waitForCustomPreview()
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"

        model.download()

        #expect(model.queue.items.isEmpty)
        #expect(model.pasteText == "https://youtu.be/dQw4w9WgXcQ")
        #expect(model.errorMessage == "Fix the custom file name pattern first. Invalid pattern: bad")
    }

    @Test func eachQueuedItemKeepsTheTemplateItWasAddedWith() async throws {
        let fake = try FakeYtDlp()
        let model = model(fake, settings: TestDefaults().relaunch())
        model.chooseDownloadFolder(fake.downloadFolder)
        model.advancedNaming = true
        model.options.naming = .custom
        model.options.customPattern = "%(title)s"
        await model.waitForCustomPreview()
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"

        model.download()
        model.options.customPattern = "%(id)s"

        #expect(model.queue.items.map(\.request.options.customPattern) == ["%(title)s"])
        await model.queue.waitUntilIdle()
    }
}
