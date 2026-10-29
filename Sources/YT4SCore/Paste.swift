import Foundation

/// The paste box contents, read as one link per line, with what each line is.
public struct Paste: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// The line as pasted, without surrounding whitespace.
        public var text: String
        /// `nil` when the line is not a YouTube link; such lines are flagged and skipped.
        public var source: Source?

        public var isValid: Bool { source != nil }

        /// The live label shown next to the line.
        public var label: String {
            switch source {
            case nil: "Not a YouTube link"
            case .video: text.contains("list=") ? "Video (only this one, not the whole playlist)" : "Video"
            case .playlist: "Playlist"
            case .channel(_, .videos): "Channel"
            case .channel(_, .shorts): "Channel (Shorts)"
            case .channel(_, .streams): "Channel (Live)"
            }
        }
    }

    /// Non-empty lines, in order.
    public let lines: [Line]

    public init(_ text: String) {
        lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Line(text: $0, source: Source(link: $0)) }
    }

    /// The Sources to download, in paste order, each once.
    public var sources: [Source] {
        var seen = Set<Source>()
        return lines.compactMap(\.source).filter { seen.insert($0).inserted }
    }

    /// Shown under the paste box when several links were pasted.
    public var summary: String? {
        let count = lines.count { $0.isValid }
        return count > 1 ? "List of \(count) links" : nil
    }

    /// The lines that are not YouTube links, left in the paste box after Download so they can be fixed.
    public var invalidText: String {
        lines.filter { !$0.isValid }.map(\.text).joined(separator: "\n")
    }
}
