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

        model.pasteText = "https://youtu.be/abc123"
        #expect(model.canDownload)
    }

    @Test func downloadQueuesThePastedLinkWithDefaultOptionsAndClearsThePasteBox() throws {
        let fake = try FakeYtDlp()
        let model = model(fake)
        model.pasteText = "  https://youtu.be/abc123 \n"

        model.download()

        #expect(model.queue.items.map(\.request) == [
            DownloadRequest(url: "https://youtu.be/abc123", downloadFolder: fake.downloadFolder, options: .default),
        ])
        #expect(model.pasteText == "")
    }

    @Test func firstDownloadCreatesTheDownloadFolder() async throws {
        let fake = try FakeYtDlp()
        let folder = fake.downloadFolder.appendingPathComponent("YT4S", isDirectory: true)
        let model = model(fake, folder: folder)
        model.pasteText = "https://youtu.be/abc123"

        model.download()
        await model.queue.waitUntilIdle()

        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(model.queue.items.first?.state == .finished(file: folder.appendingPathComponent("Fake Video abc123.mp4")))
        #expect(model.errorMessage == nil)
    }

    @Test func anUncreatableFolderShowsAPlainErrorAndQueuesNothing() throws {
        let fake = try FakeYtDlp()
        let model = model(fake, folder: URL(fileURLWithPath: "/nonexistent-yt4s-parent/YT4S", isDirectory: true))
        model.pasteText = "https://youtu.be/abc123"

        model.download()

        #expect(model.queue.items.isEmpty)
        #expect(model.errorMessage == "Couldn't create the folder /nonexistent-yt4s-parent/YT4S. Choose another Download folder.")
        #expect(model.pasteText == "https://youtu.be/abc123")
    }
}
