import Foundation

/// The custom Naming pattern, written in yt-dlp's output template language, e.g.
/// `%(channel)s/%(title)s`.
///
/// yt-dlp itself renders it (full template language: formatting, defaults, alternatives, dates)
/// as the last field of the `YT4S-DETAILS` line, never as yt-dlp's own output name. YT4S then
/// treats the result like a preset's: same cleanup, ID fallback, trimming and collision rule.
///
/// A `/` typed in the template makes a folder; a `/` inside a value (e.g. a title "AC/DC") does
/// not, as with yt-dlp's own `-o`. `--print` does not sanitize values, so literal slashes are sent
/// to yt-dlp as `folderSeparator` and split on afterwards.
public struct CustomNamingPattern: Equatable, Sendable {
    /// Stands for a folder break in the rendered text (U+001F UNIT SEPARATOR, never in a title).
    public static let folderSeparator: Character = "\u{1F}"
    /// What first choosing Custom starts from.
    public static let starter = "%(channel)s/%(title)s"

    public var text: String

    public init(_ text: String) {
        self.text = text
    }

    /// The template to `--print`: literal `/` replaced by `folderSeparator`, and a trailing
    /// `.%(ext)s` dropped, since the app always adds the Format's extension itself.
    public var printTemplate: String {
        var template = text
        if template.hasSuffix(".%(ext)s") { template.removeLast(".%(ext)s".count) }
        var result = ""
        var characters = template[...]
        while let character = characters.popFirst() {
            if character == "%" {
                // An odd run of `%` starts a field (`%%` is a literal percent sign). yt-dlp field
                // keys never contain `)`, so the field runs to the next one.
                var run = "%"
                while characters.first == "%" { run.append(characters.removeFirst()) }
                result += run
                if run.count % 2 == 1, characters.first == "(" {
                    let end = characters.firstIndex(of: ")").map { characters.index(after: $0) } ?? characters.endIndex
                    result += characters[..<end]
                    characters = characters[end...]
                }
            } else if character == "/" {
                result.append(Self.folderSeparator)
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// `--parse-metadata` flags that give a custom template the playlist fields of the video's
    /// Source (`playlist_title`, `playlist_index`, ...), which a video downloaded on its own
    /// (`--no-playlist`) would not have. None for presets or single links.
    static func originMetadata(_ request: DownloadRequest) -> [String] {
        guard request.options.naming == .custom else { return [] }
        let origin = request.origin
        let fields: [(String, String?)] = [
            ("playlist_title", origin.playlistTitle),
            ("playlist", origin.playlistTitle),
            ("playlist_index", origin.playlistIndex.map(String.init)),
            ("playlist_count", origin.playlistCount.map(String.init)),
            ("playlist_channel", origin.channelName),
            ("playlist_uploader", origin.channelName),
        ]
        return fields.flatMap { field, value -> [String] in
            guard let value else { return [] }
            // FROM is a template (hence `%%`) and ends at the first unescaped `:`.
            let literal = value.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: ":", with: "\\:")
            return ["--parse-metadata", "YT4S=\(literal):(?s)^YT4S=(?P<\(field)>.*)$"]
        }
    }
}

extension NamePlan {
    /// The plan for a rendered custom template: every `folderSeparator` part but the last is a
    /// folder, the last is the stem. No index prefix: the template replaces the auto layout.
    /// Empty parts (`a//b`, a leading `/`) are dropped by `relativePath`.
    public init(customName: String) {
        var parts = customName.split(separator: CustomNamingPattern.folderSeparator, omittingEmptySubsequences: false)
            .map(String.init)
        let stem = parts.removeLast()
        self.init(folders: parts, stem: stem)
    }
}
