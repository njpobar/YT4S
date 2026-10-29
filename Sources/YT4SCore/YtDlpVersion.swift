import Foundation

/// A yt-dlp release tag such as `2026.10.26.220202` (nightly) or `2026.10.21` (stable).
///
/// Ordered by its dot-separated numbers, so "newer" means a later release on either channel.
/// Only digits and dots are accepted, which also makes a tag safe to use as a directory name.
public struct YtDlpVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let tag: String
    private let components: [Int]

    public init?(_ tag: String) {
        let parts = tag.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        self.tag = tag
        self.components = numbers
    }

    public var description: String { tag }

    public static func < (lhs: YtDlpVersion, rhs: YtDlpVersion) -> Bool {
        for (l, r) in zip(lhs.components, rhs.components) where l != r {
            return l < r
        }
        return lhs.components.count < rhs.components.count
    }

    public static func == (lhs: YtDlpVersion, rhs: YtDlpVersion) -> Bool {
        lhs.components == rhs.components
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(components)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
