import Foundation

/// The file a Snip produces (`GLOSSARY.md`): saved next to the original, named from the
/// original's current name.
public enum SnippedCopy {
    /// Shown in the Snip window when only the Snipped copy is left to start from.
    public static let originalGoneNotice = "Snipping the Snipped copy, the original is gone"

    /// `<name> (snipped).<ext>` next to `source`, or `<name> (snipped) 2.<ext>`, `3`, ... when
    /// `isTaken` says that name is already used. When `source` is itself a Snipped copy (the
    /// original is gone), `<name>` is its name without its own ` (snipped)` / ` (snipped) N`.
    public static func file(for source: URL, sourceIsSnippedCopy: Bool = false, isTaken: (URL) -> Bool) -> URL {
        let folder = source.deletingLastPathComponent()
        var name = source.deletingPathExtension().lastPathComponent
        if sourceIsSnippedCopy, let suffix = name.range(of: #" \(snipped\)( [0-9]+)?$"#, options: .regularExpression) {
            name.removeSubrange(suffix)
        }
        let fileExtension = source.pathExtension
        for number in 1... {
            let suffix = number == 1 ? " (snipped)" : " (snipped) \(number)"
            let candidate = folder.appendingPathComponent(name + suffix).appendingPathExtension(fileExtension)
            if !isTaken(candidate) { return candidate }
        }
        fatalError("unreachable")
    }
}
