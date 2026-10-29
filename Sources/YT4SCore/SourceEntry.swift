import Foundation

extension YtDlpOutputTemplates {
    /// `--flat-playlist --print` once per video of a Playlist or Channel source, without
    /// looking each video up. Fields: id, playlist index, playlist count, url (JSON), title
    /// (JSON), playlist title (JSON), the playlist's channel (JSON), the video's channel (JSON).
    /// Upload dates are not listed in flat mode; naming gets them from the download itself.
    public static let entry =
        "YT4S-ENTRY\t%(id)s\t%(playlist_index)s\t%(playlist_count)s\t%(url)j\t%(title)j\t%(playlist_title)j\t%(playlist_channel,playlist_uploader)j\t%(channel,uploader)j"
}

/// One video listed by yt-dlp for a Playlist or Channel source.
public struct SourceEntry: Equatable, Sendable {
    public var videoID: String
    /// The single-video link to download.
    public var url: String
    public var title: String?
    /// 1-based position in the playlist or channel tab.
    public var playlistIndex: Int?
    public var playlistCount: Int?
    /// The playlist's title; for a channel, the tab's (e.g. "jawed - Videos").
    public var playlistTitle: String?
    /// The channel that owns the playlist, or the channel itself for a Channel source.
    public var playlistChannel: String?
    /// The video's own channel when yt-dlp lists it (playlists do, channel tabs do not).
    public var channel: String?

    public init(
        videoID: String,
        url: String,
        title: String?,
        playlistIndex: Int?,
        playlistCount: Int?,
        playlistTitle: String?,
        playlistChannel: String?,
        channel: String?
    ) {
        self.videoID = videoID
        self.url = url
        self.title = title
        self.playlistIndex = playlistIndex
        self.playlistCount = playlistCount
        self.playlistTitle = playlistTitle
        self.playlistChannel = playlistChannel
        self.channel = channel
    }

    /// Parses the tab-separated fields of a `YT4S-ENTRY` line (kind first).
    init?(fields: [String]) {
        guard fields.count == 9, fields[0] == "YT4S-ENTRY", !fields[1].isEmpty, fields[1] != "NA",
              let url = Self.text(fields[4])
        else { return nil }
        self.init(
            videoID: fields[1],
            url: url,
            title: Self.text(fields[5]),
            playlistIndex: Int(fields[2]),
            playlistCount: Int(fields[3]),
            playlistTitle: Self.text(fields[6]),
            playlistChannel: Self.text(fields[7]),
            channel: Self.text(fields[8])
        )
    }

    /// A `j`-converted field: a JSON string, or `NA` when missing.
    private static func text(_ field: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(field.utf8))
    }
}
