import Testing
@testable import YT4SCore

/// Parsing of the one line yt-dlp prints per video when it lists a Playlist or Channel source
/// (`--flat-playlist --print YtDlpOutputTemplates.entry`).
/// `flat-playlist` and `flat-channel` were captured from the real bundled yt-dlp
/// (2026.10.26.220202) on `playlist?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu` and `@jawed/videos`.
@Suite struct SourceEntryTests {
    @Test func parsesAPlaylistEntry() throws {
        let lines = try Fixture.lines("flat-playlist")

        #expect(lines.count == 3)
        #expect(YtDlpEvent(line: lines[1]) == .entry(SourceEntry(
            videoID: "LaOUkDBDjW8",
            url: "https://www.youtube.com/watch?v=LaOUkDBDjW8",
            title: "Rick Astley - Dance (Live at The O2, London, April 2026)",
            playlistIndex: 2,
            playlistCount: 3,
            playlistTitle: "Rick Astley Live at The O2",
            playlistChannel: "Rick Astley",
            channel: "Rick Astley"
        )))
    }

    /// A channel tab is listed as a playlist named "<channel> - Videos"; its entries carry no channel.
    @Test func parsesAChannelEntry() throws {
        let lines = try Fixture.lines("flat-channel")

        #expect(lines.map { YtDlpEvent(line: $0) } == [.entry(SourceEntry(
            videoID: "jNQXAC9IVRw",
            url: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            title: "Me at the zoo",
            playlistIndex: 1,
            playlistCount: 1,
            playlistTitle: "jawed - Videos",
            playlistChannel: "jawed",
            channel: nil
        ))])
    }

    @Test func missingValuesAreNil() {
        let line = "YT4S-ENTRY\tabcdefghijk\tNA\tNA\t\"https://www.youtube.com/watch?v=abcdefghijk\"\tNA\tNA\tNA\tNA"

        #expect(YtDlpEvent(line: line) == .entry(SourceEntry(
            videoID: "abcdefghijk",
            url: "https://www.youtube.com/watch?v=abcdefghijk",
            title: nil, playlistIndex: nil, playlistCount: nil, playlistTitle: nil, playlistChannel: nil, channel: nil
        )))
    }

    @Test func anEntryWithoutAURLIsIgnored() {
        #expect(YtDlpEvent(line: "YT4S-ENTRY\tabcdefghijk\t1\t1\tNA\t\"t\"\tNA\tNA\tNA") == nil)
    }
}
