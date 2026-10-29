import Foundation
import Testing
@testable import YT4SCore

/// Expanding a Playlist or Channel source into its videos, through the real runner on the fake yt-dlp.
@Suite struct SourceExpanderTests {
    @Test func listsEveryVideoOfAPlaylistWithoutDownloadingAnything() async throws {
        let fake = try FakeYtDlp()
        let expander = SourceExpander(runner: fake.runner(scenario: "success", extraEnvironment: ["YT4S_FAKE_PLAYLIST_IDS": "aaaaaaaaaaa,bbbbbbbbbbb"]))

        let entries = try await expander.expand(.playlist(id: "PLabc"))

        #expect(entries == [
            SourceEntry(
                videoID: "aaaaaaaaaaa", url: "https://www.youtube.com/watch?v=aaaaaaaaaaa", title: "Fake Video aaaaaaaaaaa",
                playlistIndex: 1, playlistCount: 2, playlistTitle: "Fake Playlist PLabc", playlistChannel: "Fake Channel", channel: "Fake Channel"
            ),
            SourceEntry(
                videoID: "bbbbbbbbbbb", url: "https://www.youtube.com/watch?v=bbbbbbbbbbb", title: "Fake Video bbbbbbbbbbb",
                playlistIndex: 2, playlistCount: 2, playlistTitle: "Fake Playlist PLabc", playlistChannel: "Fake Channel", channel: "Fake Channel"
            ),
        ])
        let argv = try fake.loggedArgv()
        #expect(argv.contains("--flat-playlist"))
        #expect(argv.suffix(2) == ["--", "https://www.youtube.com/playlist?list=PLabc"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fake.downloadFolder.path).isEmpty)
    }

    @Test func listsTheVideosTabOfAChannel() async throws {
        let fake = try FakeYtDlp()
        let expander = SourceExpander(runner: fake.runner(scenario: "success"))

        let entries = try await expander.expand(.channel(path: "@jawed", tab: .videos))

        #expect(entries.map(\.videoID) == ["p1", "p2", "p3"])
        #expect(entries.map(\.playlistIndex) == [1, 2, 3])
        #expect(entries.allSatisfy { $0.playlistChannel == "jawed" && $0.playlistTitle == "jawed - Videos" })
        #expect(try fake.loggedArgv().last == "https://www.youtube.com/@jawed/videos")
    }

    @Test func aPlaylistYtDlpCannotReadThrowsWithItsOutput() async throws {
        let fake = try FakeYtDlp()
        let expander = SourceExpander(runner: fake.runner(scenario: "success", extraEnvironment: [
            "YT4S_FAKE_PLAYLIST_ERROR": "[youtube:tab] PLabc: YouTube said: The playlist does not exist.",
        ]))

        await #expect(throws: SourceExpansionError(
            source: .playlist(id: "PLabc"),
            termination: .exited(1),
            details: "ERROR: [youtube:tab] PLabc: YouTube said: The playlist does not exist.\n"
        )) {
            try await expander.expand(.playlist(id: "PLabc"))
        }
    }

    @Test func anEmptyPlaylistHasNoVideos() async throws {
        let fake = try FakeYtDlp()
        let expander = SourceExpander(runner: fake.runner(scenario: "success", extraEnvironment: ["YT4S_FAKE_PLAYLIST_IDS": ""]))

        #expect(try await expander.expand(.playlist(id: "PLempty")).isEmpty)
    }

    @Test func aVideoSourceIsItselfWithoutRunningYtDlp() async throws {
        let fake = try FakeYtDlp()
        let expander = SourceExpander(runner: fake.runner(scenario: "crash"))

        #expect(try await expander.expand(.video(id: "dQw4w9WgXcQ")) == [SourceEntry(
            videoID: "dQw4w9WgXcQ", url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", title: nil,
            playlistIndex: nil, playlistCount: nil, playlistTitle: nil, playlistChannel: nil, channel: nil
        )])
        #expect(!FileManager.default.fileExists(atPath: fake.argvLog.path))
    }
}
