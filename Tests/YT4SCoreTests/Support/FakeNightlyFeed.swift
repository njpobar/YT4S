import CryptoKit
import Foundation
@testable import YT4SCore

/// An offline stand-in for GitHub: serves a nightly `releases/latest` JSON, a `yt-dlp_macos.zip`
/// built on the fly around a tiny shell script, and its `SHA2-256SUMS`.
final class FakeNightlyFeed: HTTPClient, @unchecked Sendable {
    let tag: String
    let zip: Data
    var checksums: String
    /// When set, every request fails with it (e.g. offline).
    var failure: Error?
    private let lock = NSLock()
    private var _requested: [URL] = []

    var requested: [URL] { lock.withLock { _requested } }

    static let api = YtDlpUpdater.latestNightlyAPI
    var zipURL: URL { URL(string: "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/\(tag)/yt-dlp_macos.zip")! }
    var sumsURL: URL { URL(string: "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/\(tag)/SHA2-256SUMS")! }

    /// - Parameter script: body of the fake `yt-dlp_macos`; by default it prints `tag` for `--version`.
    init(tag: String, script: String? = nil) throws {
        self.tag = tag
        let script = script ?? "#!/bin/sh\n[ \"$1\" = --version ] && echo \(tag) && exit 0\nexit 2\n"
        zip = try Self.makeZip(script: script)
        let sha = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        checksums = """
        76d70df873f95faded42e585756b656c5a8fe4cc38768427330e099b74f2807b  yt-dlp
        13b01617c8e8fe9ec89cc063eb8fc015667562f837289ded70d8fc680646df1c  yt-dlp_macos
        \(sha)  yt-dlp_macos.zip
        a4cf0d5ad8564e2b7507a029efef7cc1935b875107b3c9218e03920afc76f652  yt-dlp_win_x86.zip

        """
    }

    func data(from url: URL) async throws -> Data {
        try record(url)
        switch url {
        case Self.api:
            let json: [String: Any] = [
                "tag_name": tag,
                "assets": [
                    ["name": "SHA2-256SUMS", "browser_download_url": sumsURL.absoluteString],
                    ["name": "yt-dlp_macos", "browser_download_url": "https://example.invalid/yt-dlp_macos"],
                    ["name": "yt-dlp_macos.zip", "browser_download_url": zipURL.absoluteString],
                ],
            ]
            return try JSONSerialization.data(withJSONObject: json)
        case sumsURL:
            return Data(checksums.utf8)
        default:
            throw URLError(.fileDoesNotExist)
        }
    }

    func download(from url: URL, to destination: URL) async throws {
        try record(url)
        guard url == zipURL else { throw URLError(.fileDoesNotExist) }
        try zip.write(to: destination)
    }

    private func record(_ url: URL) throws {
        lock.withLock { _requested.append(url) }
        if let failure { throw failure }
    }

    /// A zip laid out like upstream's: `yt-dlp_macos` and `_internal/` at the top level.
    private static func makeZip(script: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yt4s-zip-\(UUID().uuidString)", isDirectory: true)
        let content = dir.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content.appendingPathComponent("_internal"), withIntermediateDirectories: true)
        let executable = content.appendingPathComponent("yt-dlp_macos")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("lib".utf8).write(to: content.appendingPathComponent("_internal/base_library.zip"))
        let zip = dir.appendingPathComponent("yt-dlp_macos.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", content.path, zip.path]
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: dir) }
        return try Data(contentsOf: zip)
    }
}
