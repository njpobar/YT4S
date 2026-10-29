import Testing
@testable import YT4SCore

/// The paste box contents: one link per line, each with a live label.
@Suite struct PasteTests {
    @Test func eachNonEmptyLineGetsALabel() {
        let paste = Paste("""
        https://youtu.be/dQw4w9WgXcQ

          https://www.youtube.com/playlist?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu
        https://www.youtube.com/@jawed
        https://vimeo.com/123
        """)

        #expect(paste.lines.map(\.text) == [
            "https://youtu.be/dQw4w9WgXcQ",
            "https://www.youtube.com/playlist?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu",
            "https://www.youtube.com/@jawed",
            "https://vimeo.com/123",
        ])
        #expect(paste.lines.map(\.label) == ["Video", "Playlist", "Channel", "Not a YouTube link"])
        #expect(paste.lines.map(\.isValid) == [true, true, true, false])
        #expect(paste.sources == [
            .video(id: "dQw4w9WgXcQ"),
            .playlist(id: "PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu"),
            .channel(path: "@jawed", tab: .videos),
        ])
    }

    @Test func aVideoOpenedFromAPlaylistSaysOnlyThatVideoIsDownloaded() {
        let paste = Paste("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu")

        #expect(paste.lines.map(\.label) == ["Video (only this one, not the whole playlist)"])
    }

    @Test func channelShortsAndLiveTabsAreNamed() {
        let paste = Paste("https://www.youtube.com/@jawed/shorts\nhttps://www.youtube.com/@jawed/streams")

        #expect(paste.lines.map(\.label) == ["Channel (Shorts)", "Channel (Live)"])
    }

    @Test func severalLinksAreAListOfLinks() {
        #expect(Paste("https://youtu.be/dQw4w9WgXcQ\nhttps://youtu.be/jNQXAC9IVRw\nnope").summary == "List of 2 links")
        #expect(Paste("https://youtu.be/dQw4w9WgXcQ\nnope").summary == nil)
        #expect(Paste("").summary == nil)
    }

    @Test func theSameLinkTwiceIsQueuedOnce() {
        let paste = Paste("https://youtu.be/dQw4w9WgXcQ\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3")

        #expect(paste.sources == [.video(id: "dQw4w9WgXcQ")])
    }

    @Test func invalidLinesAreKeptForFixing() {
        #expect(Paste("https://youtu.be/dQw4w9WgXcQ\n  nope \nvimeo.com/1\n").invalidText == "nope\nvimeo.com/1")
        #expect(Paste("https://youtu.be/dQw4w9WgXcQ").invalidText == "")
    }
}
