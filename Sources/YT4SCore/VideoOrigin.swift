import Foundation

/// Where a Queue item's video came from, and what is known about it before it is looked up.
///
/// Naming needs this: a video from a Channel source goes under `<Channel name>/`, one from a
/// Playlist source under `<Playlist title>/<NN> - `. A single video downloaded on its own
/// (`--no-playlist`) no longer knows its playlist, so the Source's details travel with the request.
public struct VideoOrigin: Equatable, Codable, Sendable {
    /// `.video` for a single link or a list of links.
    public var sourceKind: Source.Kind
    public var videoID: String?
    /// The video's title as listed; the download reports the authoritative one.
    public var title: String?
    /// The video's own channel, when listed.
    public var channel: String?
    /// The Channel source's name, or the channel that owns a Playlist source.
    public var channelName: String?
    /// The Playlist source's title (Playlist sources only).
    public var playlistTitle: String?
    /// 1-based position in the playlist or channel tab.
    public var playlistIndex: Int?
    public var playlistCount: Int?

    public init(
        sourceKind: Source.Kind,
        videoID: String? = nil,
        title: String? = nil,
        channel: String? = nil,
        channelName: String? = nil,
        playlistTitle: String? = nil,
        playlistIndex: Int? = nil,
        playlistCount: Int? = nil
    ) {
        self.sourceKind = sourceKind
        self.videoID = videoID
        self.title = title
        self.channel = channel
        self.channelName = channelName
        self.playlistTitle = playlistTitle
        self.playlistIndex = playlistIndex
        self.playlistCount = playlistCount
    }

    /// A video pasted as a link, with nothing known about it yet.
    public static let link = VideoOrigin(sourceKind: .video)

    /// One video listed for `source`.
    public init(source: Source, entry: SourceEntry) {
        switch source.kind {
        case .video:
            self.init(sourceKind: .video, videoID: entry.videoID, title: entry.title, channel: entry.channel)
        case .playlist:
            self.init(
                sourceKind: .playlist, videoID: entry.videoID, title: entry.title, channel: entry.channel,
                channelName: entry.playlistChannel, playlistTitle: entry.playlistTitle,
                playlistIndex: entry.playlistIndex, playlistCount: entry.playlistCount
            )
        case .channel:
            // The tab is listed as "<channel> - Videos"; the channel's own name is what folders use.
            let name = entry.playlistChannel ?? entry.playlistTitle
            self.init(
                sourceKind: .channel, videoID: entry.videoID, title: entry.title, channel: entry.channel ?? name,
                channelName: name, playlistIndex: entry.playlistIndex, playlistCount: entry.playlistCount
            )
        }
    }
}
