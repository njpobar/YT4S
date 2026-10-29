import Foundation

/// Which part of a channel a Channel source downloads.
///
/// A channel's home page holds its uploads as separate tabs (Videos, Shorts, Live), each
/// numbered from 1. YT4S downloads one tab: Videos, unless the link itself names Shorts or Live.
public enum ChannelTab: String, Sendable, CaseIterable {
    case videos, shorts, streams
}

/// What one pasted line asks for: a single video, a Playlist source or a Channel source.
///
/// A list of links is not a case: it is several pasted lines, each its own `Source`.
public enum Source: Hashable, Sendable {
    case video(id: String)
    case playlist(id: String)
    /// `path` is how YouTube addresses the channel: `@handle`, `channel/<id>`, `user/<name>` or `c/<name>`.
    case channel(path: String, tab: ChannelTab)

    public enum Kind: String, Codable, Sendable {
        case video, playlist, channel
    }

    public var kind: Kind {
        switch self {
        case .video: .video
        case .playlist: .playlist
        case .channel: .channel
        }
    }

    /// The canonical link YT4S hands to yt-dlp (tracking and timestamp parameters dropped).
    public var url: String {
        switch self {
        case .video(let id): "https://www.youtube.com/watch?v=\(id)"
        case .playlist(let id): "https://www.youtube.com/playlist?list=\(id)"
        case .channel(let path, let tab): "https://www.youtube.com/\(path)/\(tab.rawValue)"
        }
    }

    /// Detects what a pasted line is; `nil` when it is not a YouTube link YT4S understands.
    ///
    /// A video link that also carries `list=` (opened from a playlist or a Mix) is that one
    /// video: that is what Sarah copied, and a Mix has no end. The playlist page link
    /// (`/playlist?list=`) is what downloads a whole playlist.
    public init?(link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = components.host?.lowercased()
        else { return nil }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }

        let path = components.percentEncodedPath.split(separator: "/").map(String.init)
        let query = { (name: String) in components.queryItems?.first { $0.name == name }?.value }

        switch host {
        case "youtu.be":
            guard path.count == 1, Self.isVideoID(path[0]) else { return nil }
            self = .video(id: path[0])
        case "youtube.com", "youtube-nocookie.com":
            guard let first = path.first else { return nil }
            switch first {
            case "watch" where path.count == 1:
                if let id = query("v"), Self.isVideoID(id) {
                    self = .video(id: id)
                } else if query("v") == nil, let list = query("list"), Self.isPlaylistID(list) {
                    self = .playlist(id: list)
                } else {
                    return nil
                }
            case "playlist" where path.count == 1:
                guard let list = query("list"), Self.isPlaylistID(list) else { return nil }
                self = .playlist(id: list)
            case "shorts", "live", "embed", "v":
                guard path.count == 2, Self.isVideoID(path[1]) else { return nil }
                self = .video(id: path[1])
            case _ where first.hasPrefix("@"):
                guard first.count > 1, Self.isChannelName(first.dropFirst()), path.count <= 2 else { return nil }
                self = .channel(path: first, tab: Self.tab(path.dropFirst().first))
            case "channel", "user", "c":
                guard path.count == 2 || path.count == 3, Self.isChannelName(path[1][...]) else { return nil }
                self = .channel(path: "\(first)/\(path[1])", tab: Self.tab(path.dropFirst(2).first))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func tab(_ component: String?) -> ChannelTab {
        component.flatMap(ChannelTab.init(rawValue:)) ?? .videos
    }

    private static let idCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    private static let channelNameCharacters = idCharacters.union(CharacterSet(charactersIn: ".%"))

    private static func isVideoID(_ value: String) -> Bool {
        value.count == 11 && value.unicodeScalars.allSatisfy(idCharacters.contains)
    }

    private static func isPlaylistID(_ value: String) -> Bool {
        value.count >= 2 && value.unicodeScalars.allSatisfy(idCharacters.contains)
    }

    private static func isChannelName(_ value: Substring) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy(channelNameCharacters.contains)
    }
}
