import Testing
@testable import YT4SCore

/// What one pasted line is: a video, a Playlist source, a Channel source, or not a YouTube link.
/// Each Source carries the canonical URL YT4S hands to yt-dlp.
@Suite struct SourceDetectionTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
        "http://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ",
        "www.youtube.com/watch?v=dQw4w9WgXcQ",
        "youtube.com/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=abc",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?si=Xy12&t=10",
        "youtu.be/dQw4w9WgXcQ",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://youtube.com/shorts/dQw4w9WgXcQ?feature=share",
        "https://www.youtube.com/live/dQw4w9WgXcQ",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
        "  https://www.youtube.com/watch?v=dQw4w9WgXcQ  ",
    ])
    func videoLinks(_ link: String) {
        #expect(Source(link: link) == .video(id: "dQw4w9WgXcQ"))
    }

    @Test func aVideoSourceDownloadsTheCanonicalWatchURL() {
        #expect(Source.video(id: "dQw4w9WgXcQ").url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    /// A video opened from a playlist keeps `list=` in its link. Sarah copied a video, so it is
    /// that one video; she pastes the playlist link (or the playlist's own page) for all of it.
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu&index=2",
        "https://www.youtube.com/watch?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu&v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ&start_radio=1",
    ])
    func watchWithListIsTheVideoAlone(_ link: String) {
        #expect(Source(link: link) == .video(id: "dQw4w9WgXcQ"))
    }

    @Test(arguments: [
        "https://www.youtube.com/playlist?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu",
        "https://youtube.com/playlist?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu&si=abc",
        "https://m.youtube.com/playlist?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu",
        "https://music.youtube.com/playlist?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu",
        "https://www.youtube.com/watch?list=PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu",
    ])
    func playlistLinks(_ link: String) {
        #expect(Source(link: link) == .playlist(id: "PLlaN88a7y2_qHDbY9eQbuNTAuEJUSEeuu"))
    }

    @Test func aPlaylistSourceDownloadsThePlaylistPage() {
        #expect(Source.playlist(id: "PLx").url == "https://www.youtube.com/playlist?list=PLx")
    }

    @Test(arguments: [
        ("https://www.youtube.com/@jawed", "@jawed", ChannelTab.videos),
        ("https://youtube.com/@jawed/", "@jawed", .videos),
        ("youtube.com/@jawed?si=abc", "@jawed", .videos),
        ("https://www.youtube.com/@jawed/videos", "@jawed", .videos),
        ("https://www.youtube.com/@jawed/featured", "@jawed", .videos),
        ("https://www.youtube.com/@jawed/playlists", "@jawed", .videos),
        ("https://www.youtube.com/@jawed/shorts", "@jawed", .shorts),
        ("https://www.youtube.com/@jawed/streams", "@jawed", .streams),
        ("https://m.youtube.com/@Some.Channel-name_1", "@Some.Channel-name_1", .videos),
        ("https://www.youtube.com/@%E6%97%A5%E6%9C%AC", "@%E6%97%A5%E6%9C%AC", .videos),
        ("https://www.youtube.com/channel/UC4QobU6STFB0P71PMvOGN5A", "channel/UC4QobU6STFB0P71PMvOGN5A", .videos),
        ("https://www.youtube.com/channel/UC4QobU6STFB0P71PMvOGN5A/shorts", "channel/UC4QobU6STFB0P71PMvOGN5A", .shorts),
        ("https://www.youtube.com/user/RickAstleyVEVO", "user/RickAstleyVEVO", .videos),
        ("https://www.youtube.com/c/RickAstley/videos", "c/RickAstley", .videos),
    ])
    func channelLinks(_ link: String, path: String, tab: ChannelTab) {
        #expect(Source(link: link) == .channel(path: path, tab: tab))
    }

    /// A channel's home page lists its tabs as separate playlists (Videos, Shorts, Live), each
    /// numbered from 1. YT4S downloads the Videos tab unless the link names Shorts or Live.
    @Test func aChannelSourceDownloadsOneTab() {
        #expect(Source.channel(path: "@jawed", tab: .videos).url == "https://www.youtube.com/@jawed/videos")
        #expect(Source.channel(path: "channel/UC4Q", tab: .streams).url == "https://www.youtube.com/channel/UC4Q/streams")
    }

    @Test(arguments: [
        "",
        "hello",
        "dQw4w9WgXcQ",
        "https://vimeo.com/123456",
        "https://www.youtube.com/",
        "https://www.youtube.com/feed/subscriptions",
        "https://www.youtube.com/results?search_query=rick",
        "https://www.youtube.com/watch?v=short",
        "https://youtu.be/",
        "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
        "ftp://youtube.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ https://youtu.be/dQw4w9WgXcQ",
        "-o /tmp/x https://youtu.be/dQw4w9WgXcQ",
    ])
    func notYouTubeLinks(_ link: String) {
        #expect(Source(link: link) == nil)
    }

    @Test func kinds() {
        #expect(Source.video(id: "a").kind == .video)
        #expect(Source.playlist(id: "a").kind == .playlist)
        #expect(Source.channel(path: "@a", tab: .videos).kind == .channel)
    }
}
