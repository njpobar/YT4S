import Foundation
import Testing
@testable import YT4SCore

/// Download with every kind of Source, end to end on the fake yt-dlp: each Source becomes one
/// Queue row per video, in paste order, carrying what naming needs later.
@MainActor @Suite struct MainWindowSourceTests {
    private func model(_ fake: FakeYtDlp, _ environment: [String: String] = [:]) -> MainWindowModel {
        MainWindowModel(
            queue: Queue(runner: fake.runner(scenario: "success", extraEnvironment: environment)),
            downloadFolder: fake.downloadFolder
        )
    }

    @Test func thePasteBoxLabelsEachLineLive() throws {
        let model = model(try FakeYtDlp())

        model.pasteText = "https://www.youtube.com/@jawed\nnot a link"

        #expect(model.paste.lines.map(\.label) == ["Channel", "Not a YouTube link"])
    }

    @Test func onlyInvalidLinesCannotBeDownloaded() throws {
        let model = model(try FakeYtDlp())

        model.pasteText = "https://vimeo.com/1\nhello"

        #expect(!model.canDownload)
    }

    @Test func aPlaylistBecomesOneRowPerVideoWithItsTitleAndIndex() async throws {
        let fake = try FakeYtDlp()
        let model = model(fake, ["YT4S_FAKE_PLAYLIST_IDS": "aaaaaaaaaaa,bbbbbbbbbbb"])
        model.pasteText = "https://www.youtube.com/playlist?list=PLabc"

        model.download()
        #expect(model.pasteText == "")
        await model.waitUntilListed()

        #expect(model.queue.items.map(\.request) == [
            DownloadRequest(
                url: "https://www.youtube.com/watch?v=aaaaaaaaaaa", downloadFolder: fake.downloadFolder, options: .default,
                origin: VideoOrigin(
                    sourceKind: .playlist, videoID: "aaaaaaaaaaa", title: "Fake Video aaaaaaaaaaa", channel: "Fake Channel",
                    channelName: "Fake Channel", playlistTitle: "Fake Playlist PLabc", playlistIndex: 1, playlistCount: 2
                )
            ),
            DownloadRequest(
                url: "https://www.youtube.com/watch?v=bbbbbbbbbbb", downloadFolder: fake.downloadFolder, options: .default,
                origin: VideoOrigin(
                    sourceKind: .playlist, videoID: "bbbbbbbbbbb", title: "Fake Video bbbbbbbbbbb", channel: "Fake Channel",
                    channelName: "Fake Channel", playlistTitle: "Fake Playlist PLabc", playlistIndex: 2, playlistCount: 2
                )
            ),
        ])
        // Rows show the title before each video starts.
        #expect(model.queue.items.map(\.title) == ["Fake Video aaaaaaaaaaa", "Fake Video bbbbbbbbbbb"])
        await model.queue.waitUntilIdle()
        #expect(model.queue.items.allSatisfy { $0.isFinished })
    }

    @Test func aChannelKeepsTheChannelName() async throws {
        let fake = try FakeYtDlp()
        let model = model(fake, ["YT4S_FAKE_PLAYLIST_IDS": "aaaaaaaaaaa"])
        model.pasteText = "https://www.youtube.com/@jawed"

        model.download()
        await model.waitUntilListed()

        #expect(model.queue.items.map(\.request.origin) == [VideoOrigin(
            sourceKind: .channel, videoID: "aaaaaaaaaaa", title: "Fake Video aaaaaaaaaaa", channel: "jawed",
            channelName: "jawed", playlistTitle: nil, playlistIndex: 1, playlistCount: 1
        )])
    }

    @Test func aListOfLinksBecomesOneRowPerLinkInPasteOrder() async throws {
        let fake = try FakeYtDlp()
        let model = model(fake, ["YT4S_FAKE_PLAYLIST_IDS": "ppppppppppp"])
        model.pasteText = """
        https://youtu.be/aaaaaaaaaaa
        https://www.youtube.com/playlist?list=PLabc
        not a link
        https://www.youtube.com/shorts/bbbbbbbbbbb
        """

        model.download()
        await model.waitUntilListed()

        #expect(model.queue.items.map(\.request.url) == [
            "https://www.youtube.com/watch?v=aaaaaaaaaaa",
            "https://www.youtube.com/watch?v=ppppppppppp",
            "https://www.youtube.com/watch?v=bbbbbbbbbbb",
        ])
        #expect(model.queue.items.map(\.request.origin.sourceKind) == [.video, .playlist, .video])
        // The invalid line was never sent to yt-dlp and stays in the paste box to be fixed.
        #expect(model.pasteText == "not a link")
        await model.queue.waitUntilIdle()
        let argv = try fake.loggedArgv()
        #expect(!argv.contains("not a link"))
    }

    @Test func aPlaylistThatCannotBeListedIsReportedAndTheRestStillQueues() async throws {
        let fake = try FakeYtDlp()
        let model = model(fake, ["YT4S_FAKE_PLAYLIST_ERROR": "[youtube:tab] PLabc: YouTube said: The playlist does not exist."])
        model.pasteText = "https://www.youtube.com/playlist?list=PLabc\nhttps://youtu.be/aaaaaaaaaaa"

        model.download()
        await model.waitUntilListed()

        #expect(model.queue.items.map(\.request.url) == ["https://www.youtube.com/watch?v=aaaaaaaaaaa"])
        #expect(model.errorMessage == "Couldn't list the videos of the playlist https://www.youtube.com/playlist?list=PLabc. Check the link, or try again later.")
    }

    @Test func anEmptyChannelIsReported() async throws {
        let fake = try FakeYtDlp()
        let model = model(fake, ["YT4S_FAKE_PLAYLIST_IDS": ""])
        model.pasteText = "https://www.youtube.com/@jawed/shorts"

        model.download()
        await model.waitUntilListed()

        #expect(model.queue.items.isEmpty)
        #expect(model.errorMessage == "The channel https://www.youtube.com/@jawed/shorts has no videos.")
    }

    @Test func whileListingTheModelSaysSo() async throws {
        let fake = try FakeYtDlp()
        let model = model(fake)
        model.pasteText = "https://www.youtube.com/playlist?list=PLabc"

        model.download()
        #expect(model.listingMessage == "Looking up the videos of 1 playlist...")

        await model.waitUntilListed()
        #expect(model.listingMessage == nil)
    }

    @Test func listingCountsAsDownloadsRunningSoUpdatesStayDisabled() async throws {
        let fake = try FakeYtDlp()
        let model = model(fake, ["YT4S_FAKE_LIST_DELAY": "1", "YT4S_FAKE_PLAYLIST_IDS": "aaaaaaaaaaa"])
        model.pasteText = "https://www.youtube.com/playlist?list=PLabc"
        #expect(!model.downloadsRunning)

        model.download()
        #expect(model.queue.items.isEmpty)
        #expect(model.downloadsRunning)

        await model.waitUntilListed()
        await model.queue.waitUntilIdle()
        #expect(!model.downloadsRunning)
    }
}
