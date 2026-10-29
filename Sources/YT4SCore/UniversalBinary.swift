import Foundation

/// Keeps only the arm64 half of universal ("fat") Mach-O files, like `lipo -thin arm64` (which
/// needs the developer tools, so YT4S cannot run it on Sarah's Mac). YT4S runs on Apple Silicon
/// only; upstream yt-dlp ships x86_64 + arm64. Each slice carries its own code signature, so the
/// extracted slice runs as is.
public enum UniversalBinary {
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let cpuTypeARM64: UInt32 = 0x0100_000C

    /// Thins every universal file under `folder` (recursively, symlinks not followed). Files
    /// that are not universal, or have no arm64 slice, are left alone.
    public static func thinToArm64(in folder: URL) throws {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try thinToArm64(file: file)
        }
    }

    /// Replaces `file` with its arm64 slice, keeping its permissions.
    static func thinToArm64(file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        let header = try handle.read(upToCount: 8) ?? Data()
        guard header.count == 8, let magic = header.bigEndianUInt32(at: 0), magic == fatMagic || magic == fatMagic64,
              let count = header.bigEndianUInt32(at: 4), count > 0, count < 64
        else {
            try handle.close()
            return
        }
        let entrySize = magic == fatMagic64 ? 32 : 20
        let table = try handle.read(upToCount: Int(count) * entrySize) ?? Data()
        var slice: (offset: UInt64, size: UInt64)?
        for index in 0..<Int(count) {
            let entry = index * entrySize
            guard table.bigEndianUInt32(at: entry) == cpuTypeARM64 else { continue }
            if magic == fatMagic64 {
                guard let offset = table.bigEndianUInt64(at: entry + 8), let size = table.bigEndianUInt64(at: entry + 16) else { break }
                slice = (offset, size)
            } else {
                guard let offset = table.bigEndianUInt32(at: entry + 8), let size = table.bigEndianUInt32(at: entry + 12) else { break }
                slice = (UInt64(offset), UInt64(size))
            }
            break
        }
        guard let slice else {
            try handle.close()
            return
        }
        try handle.seek(toOffset: slice.offset)
        let data = try handle.read(upToCount: Int(slice.size)) ?? Data()
        try handle.close()
        guard data.count == Int(slice.size) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: file]) }

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        let thinned = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).arm64")
        try data.write(to: thinned)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: thinned.path) }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: thinned)
    }
}

private extension Data {
    func bigEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return self[startIndex + offset..<startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func bigEndianUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return self[startIndex + offset..<startIndex + offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
