import Foundation

/// The file a Snip produces (`GLOSSARY.md`): saved next to the original, named from the
/// original's current name.
public enum SnippedCopy {
    /// `<name> (snipped).<ext>` next to `original`, or `<name> (snipped) 2.<ext>`, `3`, ... when
    /// `isTaken` says that name is already used.
    public static func file(for original: URL, isTaken: (URL) -> Bool) -> URL {
        let folder = original.deletingLastPathComponent()
        let name = original.deletingPathExtension().lastPathComponent
        let fileExtension = original.pathExtension
        for number in 1... {
            let suffix = number == 1 ? " (snipped)" : " (snipped) \(number)"
            let candidate = folder.appendingPathComponent(name + suffix).appendingPathExtension(fileExtension)
            if !isTaken(candidate) { return candidate }
        }
        fatalError("unreachable")
    }
}
