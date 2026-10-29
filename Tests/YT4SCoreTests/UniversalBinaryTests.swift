import Foundation
import Testing
@testable import YT4SCore

/// Downloaded yt-dlp copies are universal (x86_64 + arm64); YT4S keeps only the arm64 half, the
/// same thinning `build-app.sh` does for the bundled copy. Each slice carries its own signature,
/// so the arm64 slice runs as is.
@Suite struct UniversalBinaryTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("yt4s-thin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("_internal"), withIntermediateDirectories: true)
    }

    private let arm64Slice = Data("arm64 slice: \u{FE}\u{ED}\u{FA}\u{CF} code".utf8)
    private let x86Slice = Data("x86_64 slice".utf8)

    /// A fat file like `lipo -create` writes: header, arch table, page-aligned slices.
    private func fatFile(_ slices: [(cpuType: UInt32, data: Data)]) -> Data {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        append(0xCAFE_BABE)
        append(UInt32(slices.count))
        var offset: UInt32 = 0x4000
        var layout: [(UInt32, Data)] = []
        for slice in slices {
            append(slice.cpuType)
            append(0) // cpusubtype
            append(offset)
            append(UInt32(slice.data.count))
            append(14) // 2^14 alignment
            layout.append((offset, slice.data))
            offset += 0x4000
        }
        for (sliceOffset, slice) in layout {
            data.append(Data(count: Int(sliceOffset) - data.count))
            data.append(slice)
        }
        return data
    }

    @Test func universalFilesKeepOnlyTheirArm64SliceAndTheirPermissions() throws {
        let executable = folder.appendingPathComponent("yt-dlp_macos")
        let library = folder.appendingPathComponent("_internal/libssl.3.dylib")
        try fatFile([(0x0100_0007, x86Slice), (0x0100_000C, arm64Slice)]).write(to: executable)
        try fatFile([(0x0100_000C, arm64Slice), (0x0100_0007, x86Slice)]).write(to: library)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try UniversalBinary.thinToArm64(in: folder)

        #expect(try Data(contentsOf: executable) == arm64Slice)
        #expect(try Data(contentsOf: library) == arm64Slice)
        let permissions = try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
    }

    @Test func otherFilesAreLeftAlone() throws {
        let script = folder.appendingPathComponent("yt-dlp_macos")
        let x86Only = folder.appendingPathComponent("_internal/x86.so")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
        let fatWithoutArm64 = fatFile([(0x0100_0007, x86Slice)])
        try fatWithoutArm64.write(to: x86Only)

        try UniversalBinary.thinToArm64(in: folder)

        #expect(try Data(contentsOf: script) == Data("#!/bin/sh\necho hi\n".utf8))
        #expect(try Data(contentsOf: x86Only) == fatWithoutArm64)
    }

    /// The real upstream onedir: thinned, it still starts. Needs `vendor/` (scripts/fetch-deps.sh).
    @Test(.enabled(if: UniversalBinaryTests.vendorYtDlp != nil))
    func theRealYtDlpOnedirStillRunsThinned() async throws {
        let copy = folder.appendingPathComponent("yt-dlp", isDirectory: true)
        let ditto = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [try #require(Self.vendorYtDlp).path, copy.path]
        )
        #expect(ditto.termination == .exited(0))

        try UniversalBinary.thinToArm64(in: copy)

        let executable = copy.appendingPathComponent("yt-dlp_macos")
        let kind = try await Subprocess.run(executable: URL(fileURLWithPath: "/usr/bin/file"), arguments: ["-b", executable.path])
        #expect(!kind.stdout.contains("universal"))
        let version = try await Subprocess.run(executable: executable, arguments: ["--version"])
        #expect(version.termination == .exited(0))
        #expect(YtDlpVersion(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    }

    /// The repo's fetched (universal) yt-dlp onedir, if present.
    static var vendorYtDlp: URL? {
        let vendor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/yt-dlp", isDirectory: true)
        return FileManager.default.fileExists(atPath: vendor.appendingPathComponent("yt-dlp_macos").path) ? vendor : nil
    }
}
