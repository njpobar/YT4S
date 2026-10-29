import CryptoKit
import Foundation

/// The network seam of the yt-dlp updater. `URLSessionHTTPClient` in the app, a fake in tests.
public protocol HTTPClient: Sendable {
    /// GETs a small resource (release JSON, checksum list). Throws on transport errors and non-2xx.
    func data(from url: URL) async throws -> Data
    /// GETs a large resource straight to `destination` (which must not exist yet).
    func download(from url: URL, to destination: URL) async throws
}

/// Why Update yt-dlp did not install anything. In every case the current yt-dlp stays in use and
/// nothing is left behind in staging.
public enum YtDlpUpdateError: Error, Equatable, Sendable {
    /// No connection to GitHub.
    case offline
    /// GitHub answered with an error, or a transfer broke off.
    case network
    /// The latest release has no usable `yt-dlp_macos.zip` / `SHA2-256SUMS` or a malformed tag.
    case releaseUnusable
    /// The zip's SHA-256 is not the one listed in `SHA2-256SUMS` (or is not listed at all).
    case checksumMismatch
    /// The verified zip could not be unpacked.
    case unpackFailed
    /// The unpacked yt-dlp did not run `--version` and print its tag.
    case smokeTestFailed
    /// Moving it into place or writing `state.json` failed (disk full, permissions).
    case installFailed

    /// Two or three short lines for the footer: what failed and what to do.
    public func explanation(current: String) -> String {
        let kept = "You're still on yt-dlp \(current)."
        return switch self {
        case .offline:
            "Couldn't reach GitHub to download yt-dlp. \(kept)\nCheck your internet connection, then try again."
        case .network:
            "The yt-dlp download from GitHub didn't finish. \(kept)\nTry again in a few minutes."
        case .releaseUnusable:
            "The latest yt-dlp release on GitHub isn't complete yet. \(kept)\nTry again later."
        case .checksumMismatch:
            "The downloaded yt-dlp didn't match its checksum, so it wasn't installed. \(kept)\nTry again later."
        case .unpackFailed, .smokeTestFailed:
            "The new yt-dlp didn't start correctly, so it wasn't installed. \(kept)\nTry again later."
        case .installFailed:
            "Couldn't save the new yt-dlp. Check that your Mac has free disk space. \(kept)"
        }
    }
}

public enum YtDlpUpdateOutcome: Equatable, Sendable {
    /// The latest nightly is not newer than what runs now; nothing was downloaded.
    case upToDate(YtDlpCopy)
    /// The latest nightly is now active.
    case installed(YtDlpCopy)
}

/// Updates yt-dlp from the upstream nightly channel (ADR 0002). Never uses `yt-dlp -U`.
///
/// Update: latest release -> download zip + `SHA2-256SUMS` -> verify SHA-256 -> unzip to staging ->
/// thin to arm64 -> `--version` smoke test -> atomic rename into `<root>/<tag>/` -> flip `state.json`.
/// Any failure discards staging and throws, leaving the current copy in use. No retries.
public struct YtDlpUpdater: Sendable {
    public static let latestNightlyAPI = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp-nightly-builds/releases/latest")!
    static let zipAsset = "yt-dlp_macos.zip"
    static let checksumsAsset = "SHA2-256SUMS"

    public let installations: YtDlpInstallations
    let http: HTTPClient
    let smokeTestTimeout: Duration

    public init(installations: YtDlpInstallations, http: HTTPClient, smokeTestTimeout: Duration = .seconds(120)) {
        self.installations = installations
        self.http = http
        self.smokeTestTimeout = smokeTestTimeout
    }

    /// The latest nightly if it is newer than the copy in use, for the badge. Downloads nothing.
    /// Offers nothing while Roll back's pin is set.
    public func check() async throws -> YtDlpVersion? {
        let release = try await latestRelease()
        guard !installations.readState().pinned, isNewer(release.version) else { return nil }
        return release.version
    }

    /// Clicking it also ends Roll back's pin, even when nothing newer is installed.
    public func update() async throws -> YtDlpUpdateOutcome {
        let release = try await latestRelease()
        guard isNewer(release.version) else {
            var state = installations.readState()
            if state.pinned {
                state.pinned = false
                try? installations.writeState(state)
            }
            return .upToDate(installations.current())
        }
        guard let zipURL = release.assets[Self.zipAsset], let sumsURL = release.assets[Self.checksumsAsset] else {
            throw YtDlpUpdateError.releaseUnusable
        }

        let staging: URL
        do { staging = try installations.makeStagingDirectory() } catch { throw YtDlpUpdateError.installFailed }
        var installed = false
        defer { if !installed { try? FileManager.default.removeItem(at: staging) } }

        // The zip is downloaded next to (not into) the folder that becomes the copy.
        let zip = staging.appendingPathComponent(Self.zipAsset)
        let content = staging.appendingPathComponent("content", isDirectory: true)
        let sums = try await fetch { try await http.data(from: sumsURL) }
        try await fetch { try await http.download(from: zipURL, to: zip) }

        guard let expected = Self.checksum(for: Self.zipAsset, in: String(decoding: sums, as: UTF8.self)),
              let actual = try? Self.sha256(of: zip),
              actual == expected
        else { throw YtDlpUpdateError.checksumMismatch }

        try await unpack(zip, into: content)
        try await smokeTest(content.appendingPathComponent(YtDlpInstallations.executableName), expecting: release.version)

        do {
            let copy = try installations.install(content, as: release.version)
            installed = true
            try? FileManager.default.removeItem(at: staging)
            return .installed(copy)
        } catch {
            throw YtDlpUpdateError.installFailed
        }
    }

    /// At launch, and mid-session when the copy in use fails to start: the first copy of
    /// `installations.fallbackChain()` (active, previous, bundled) whose `--version` runs, or
    /// `nil` when none does and the app is damaged. Changes nothing on disk, so a copy that
    /// failed once is tried again at the next launch.
    public func firstLaunchableCopy() async -> YtDlpCopy? {
        for copy in installations.fallbackChain() where await version(of: copy.executable) != nil {
            return copy
        }
        return nil
    }

    // MARK: Steps

    struct Release {
        var version: YtDlpVersion
        var assets: [String: URL]
    }

    func latestRelease() async throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable {
                var name: String
                var browser_download_url: String
            }
            var tag_name: String
            var assets: [Asset]
        }
        let data = try await fetch { try await http.data(from: Self.latestNightlyAPI) }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = YtDlpVersion(payload.tag_name)
        else { throw YtDlpUpdateError.releaseUnusable }
        var assets: [String: URL] = [:]
        for asset in payload.assets {
            if let url = URL(string: asset.browser_download_url) { assets[asset.name] = url }
        }
        return Release(version: version, assets: assets)
    }

    private func isNewer(_ version: YtDlpVersion) -> Bool {
        guard let current = installations.current().version else { return true }
        return version > current
    }

    private func unpack(_ zip: URL, into directory: URL) async throws {
        // ditto keeps the onedir's permissions and symlinks.
        let result = try? await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", zip.path, directory.path]
        )
        guard result?.termination == .exited(0) else { throw YtDlpUpdateError.unpackFailed }
        try? FileManager.default.removeItem(at: zip)
        // Apple Silicon only, like the bundled copy (build-app.sh): halves the copy on disk. The
        // smoke test that follows runs the thinned copy.
        do { try UniversalBinary.thinToArm64(in: directory) } catch { throw YtDlpUpdateError.unpackFailed }
    }

    private func smokeTest(_ executable: URL, expecting version: YtDlpVersion) async throws {
        guard let output = await self.version(of: executable), YtDlpVersion(output) == version else {
            throw YtDlpUpdateError.smokeTestFailed
        }
    }

    /// What `executable --version` prints, or `nil` if it does not start, exit 0 and print
    /// something within `smokeTestTimeout`.
    private func version(of executable: URL) async -> String? {
        let timeout = smokeTestTimeout
        let output: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                guard let result = try? await Subprocess.run(executable: executable, arguments: ["--version"]),
                      result.termination == .exited(0)
                else { return nil }
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return output?.isEmpty == false ? output : nil
    }

    @discardableResult
    private func fetch<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            throw YtDlpUpdateError.offline
        } catch {
            throw YtDlpUpdateError.network
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed,
    ]

    // MARK: Checksums

    /// The SHA-256 listed for `name` in a `SHA2-256SUMS` file (`<hex>  <name>` per line).
    static func checksum(for name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            let file = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1]
            if file == name { return fields[0].lowercased() }
        }
        return nil
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// `HTTPClient` over `URLSession`.
public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return data
    }

    public func download(from url: URL, to destination: URL) async throws {
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.check(response)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
