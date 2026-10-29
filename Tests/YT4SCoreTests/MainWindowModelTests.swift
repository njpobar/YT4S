import Foundation
import Testing
@testable import YT4SCore

@MainActor @Suite struct MainWindowModelTests {
    private func model(_ fake: FakeYtDlp, folder: URL? = nil) -> MainWindowModel {
        MainWindowModel(
            queue: Queue(runner: fake.runner(scenario: "success")),
            downloadFolder: folder ?? fake.downloadFolder
        )
    }

    @Test func defaultDownloadFolderIsYT4SInDownloads() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        #expect(MainWindowModel.defaultDownloadFolder == downloads.appendingPathComponent("YT4S", isDirectory: true))
    }

    @Test func downloadIsDisabledUntilSomethingIsPasted() throws {
        let model = model(try FakeYtDlp())
        #expect(!model.canDownload)

        model.pasteText = "  \n "
        #expect(!model.canDownload)

        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"
        #expect(model.canDownload)
    }

    @Test func downloadQueuesThePastedLinkWithDefaultOptionsAndClearsThePasteBox() throws {
        let fake = try FakeYtDlp()
        let model = model(fake)
        model.pasteText = "  https://youtu.be/dQw4w9WgXcQ \n"

        model.download()

        #expect(model.queue.items.map(\.request) == [
            DownloadRequest(
                url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", downloadFolder: fake.downloadFolder, options: .default,
                origin: VideoOrigin(sourceKind: .video, videoID: "dQw4w9WgXcQ")
            ),
        ])
        #expect(model.pasteText == "")
    }

    @Test func eachQueuedItemKeepsTheFormatAndQualityChosenWhenItWasAdded() throws {
        let fake = try FakeYtDlp()
        let model = model(fake)
        model.options.quality = .p720
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"
        model.download()

        model.options.format = .mp3
        model.pasteText = "https://youtu.be/jNQXAC9IVRw"
        model.download()

        #expect(model.queue.items.map(\.request.options.format) == [.video, .mp3])
        #expect(model.queue.items.map(\.request.options.quality) == [.p720, .p720])
    }

    @Test func theQualityPresetOnlyAppliesToVideo() {
        #expect(Format.video.usesQualityPreset)
        #expect(!Format.mp3.usesQualityPreset)
    }

    @Test func firstDownloadCreatesTheDownloadFolder() async throws {
        let fake = try FakeYtDlp()
        let folder = fake.downloadFolder.appendingPathComponent("YT4S", isDirectory: true)
        let model = model(fake, folder: folder)
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"

        model.download()
        await model.queue.waitUntilIdle()

        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(model.queue.items.first?.state == .finished(file: folder.appendingPathComponent("Fake Video dQw4w9WgXcQ.mp4")))
        #expect(model.errorMessage == nil)
    }

    @Test func startsFromTheSavedSettings() throws {
        let fake = try FakeYtDlp()
        let suite = TestDefaults()
        suite.relaunch().downloadFolder = fake.downloadFolder

        let model = MainWindowModel(queue: Queue(runner: fake.runner(scenario: "success")), settings: suite.relaunch())
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"
        model.download()

        #expect(model.downloadFolder == suite.relaunch().downloadFolder)
        #expect(model.options == .default)
        #expect(model.queue.items.map(\.request.downloadFolder) == [fake.downloadFolder])
    }

    @Test func firstLaunchUsesTheDefaultFolderWithoutCreatingIt() throws {
        let fake = try FakeYtDlp()
        let model = MainWindowModel(queue: Queue(runner: fake.runner(scenario: "success")), settings: TestDefaults().relaunch())

        #expect(model.downloadFolder == MainWindowModel.defaultDownloadFolder)
        #expect(model.options == DownloadOptions(format: .video, quality: .best, naming: .title))
        #expect(model.errorMessage == nil)
    }

    @Test func changingTheFolderOrOptionsIsSavedButThePasteBoxAndQueueAreNot() async throws {
        let fake = try FakeYtDlp()
        let suite = TestDefaults()
        let model = MainWindowModel(queue: Queue(runner: fake.runner(scenario: "success")), settings: suite.relaunch())

        model.chooseDownloadFolder(fake.downloadFolder)
        model.options = .default
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"
        model.download()
        await model.queue.waitUntilIdle()
        model.pasteText = "https://youtu.be/jNQXAC9IVRw"

        let relaunched = MainWindowModel(queue: Queue(runner: fake.runner(scenario: "success")), settings: suite.relaunch())
        #expect(relaunched.downloadFolder == fake.downloadFolder)
        #expect(suite.defaults.string(forKey: Settings.Key.format) == "video")
        #expect(relaunched.pasteText == "")
        #expect(relaunched.queue.items.isEmpty)
    }

    @Test func choosingAFolderClearsTheFolderError() throws {
        let fake = try FakeYtDlp()
        let model = model(fake, folder: URL(fileURLWithPath: "/nonexistent-yt4s-parent/YT4S", isDirectory: true))
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"
        model.download()
        #expect(model.errorMessage != nil)

        model.chooseDownloadFolder(fake.downloadFolder)

        #expect(model.errorMessage == nil)
        #expect(model.downloadFolder == fake.downloadFolder)
    }

    @Test func aDeletedFolderIsRecreatedWhenItsParentExists() async throws {
        let fake = try FakeYtDlp()
        let folder = fake.downloadFolder.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let model = model(fake, folder: folder)
        try FileManager.default.removeItem(at: folder)
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"

        model.download()
        await model.queue.waitUntilIdle()

        #expect(model.downloadFolder == folder)
        #expect(model.queue.items.first?.state == .finished(file: folder.appendingPathComponent("Fake Video dQw4w9WgXcQ.mp4")))
    }

    @Test func aFileWhereTheFolderShouldBeIsAnErrorNotADownload() throws {
        let fake = try FakeYtDlp()
        let file = fake.downloadFolder.appendingPathComponent("NotAFolder")
        try Data().write(to: file)
        let model = model(fake, folder: file)
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"

        model.download()

        #expect(model.queue.items.isEmpty)
        #expect(model.errorMessage == "Couldn't create the folder \(file.path). Choose another Download folder.")
    }

    @Test func aMissingFolderWithAMissingParentNeverFallsBackToAnotherFolder() throws {
        let fake = try FakeYtDlp()
        let suite = TestDefaults()
        let gone = URL(fileURLWithPath: "/nonexistent-yt4s-parent/YT4S", isDirectory: true)
        suite.relaunch().downloadFolder = gone
        let model = MainWindowModel(queue: Queue(runner: fake.runner(scenario: "success")), settings: suite.relaunch())
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"

        model.download()

        #expect(model.queue.items.isEmpty)
        #expect(model.downloadFolder == gone)
        #expect(suite.relaunch().downloadFolder == gone)
        #expect(model.errorMessage == "Couldn't create the folder /nonexistent-yt4s-parent/YT4S. Choose another Download folder.")
    }

    @Test func anUncreatableFolderShowsAPlainErrorAndQueuesNothing() throws {
        let fake = try FakeYtDlp()
        let model = model(fake, folder: URL(fileURLWithPath: "/nonexistent-yt4s-parent/YT4S", isDirectory: true))
        model.pasteText = "https://youtu.be/dQw4w9WgXcQ"

        model.download()

        #expect(model.queue.items.isEmpty)
        #expect(model.errorMessage == "Couldn't create the folder /nonexistent-yt4s-parent/YT4S. Choose another Download folder.")
        #expect(model.pasteText == "https://youtu.be/dQw4w9WgXcQ")
    }
}
