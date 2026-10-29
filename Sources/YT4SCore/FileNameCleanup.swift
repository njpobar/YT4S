import Foundation

/// Makes text safe as one macOS file or folder name: strips emoji, replaces `/` and `:`,
/// turns control characters into spaces, drops leading dots (hidden files), collapses spaces.
/// Every other character (accents, CJK, symbols) is kept.
enum FileNameCleanup {
    /// macOS limit for one name, in UTF-8 bytes. Measured decomposed (NFD), the longest form a
    /// filesystem may store, so a trimmed name fits on APFS and HFS+ alike.
    static let maxNameBytes = 255

    static func clean(_ text: String) -> String {
        var out = ""
        var characters = text.makeIterator()
        var next = characters.next()
        while let character = next {
            next = characters.next()
            if isEmoji(character) { continue }
            switch character {
            case "/":
                out.append("-")
            case ":":
                // "Title: Part" reads as "Title - Part"; "12:30" as "12-30".
                out.append(next?.isWhitespace == true ? " -" : "-")
            default:
                let isControl = character.unicodeScalars.contains { $0.properties.generalCategory == .control }
                out.append(character.isWhitespace || isControl ? " " : character)
            }
        }
        let words = out.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return String(words.drop(while: { $0 == "." || $0 == " " }))
    }

    /// The UTF-8 size of `name` as the filesystem may store it.
    static func byteCount(_ name: String) -> Int {
        name.decomposedStringWithCanonicalMapping.utf8.count
    }

    /// Cuts `name` at a character boundary so it takes at most `limit` bytes; no trailing space.
    static func trim(_ name: String, toBytes limit: Int) -> String {
        guard byteCount(name) > limit else { return name }
        var result = ""
        var used = 0
        for character in name {
            let size = byteCount(String(character))
            if used + size > limit { break }
            result.append(character)
            used += size
        }
        while result.last == " " { result.removeLast() }
        return result
    }

    /// Emoji pictographs, flags, keycaps and emoji-style symbols (`❤️`), but not text-style
    /// symbols such as `©`, `♥` or plain digits.
    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        guard scalars.count > 1, scalars.first?.properties.isEmoji == true else { return false }
        // U+FE0F asks for emoji style, U+20E3 makes a keycap, U+200D joins emoji.
        return scalars.contains { [0xFE0F, 0x20E3, 0x200D].contains($0.value) }
    }
}
