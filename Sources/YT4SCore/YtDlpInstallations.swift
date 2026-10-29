import Foundation
import os

/// The `state.json` pointer next to the downloaded yt-dlp copies (ADR 0002).
///
/// Tags name directories under the installations root. `nil` means "none downloaded".
/// - `active`: the downloaded copy in use (when it is newer than the bundled one).
/// - `previous`: the one downloaded copy kept for Roll back and the launch fallback chain.
/// - `pinned`: set by Roll back so the update check does not re-offer the version rolled back
///   from; cleared when the user clicks Update yt-dlp again.
public struct YtDlpState: Codable, Equatable, Sendable {
    public static let schema = 1

    public var active: String?
    public var previous: String?
    public var pinned: Bool

    public init(active: String? = nil, previous: String? = nil, pinned: Bool = false) {
        self.active = active
        self.previous = previous
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey { case schema, active, previous, pinned }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(String.self, forKey: .active)
        previous = try container.decodeIfPresent(String.self, forKey: .previous)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .schema)
        try container.encode(active, forKey: .active)
        try container.encode(previous, forKey: .previous)
        try container.encode(pinned, forKey: .pinned)
    }
}

/// The read-only yt-dlp floor shipped inside the app.
public struct BundledYtDlp: Equatable, Sendable {
    public var executable: URL
    /// `nil` when unknown (a development build without the version file): downloaded copies then
    /// always win and nothing is pruned.
    public var version: YtDlpVersion?

    public init(executable: URL, version: YtDlpVersion?) {
        self.executable = executable
        self.version = version
    }

    /// Layout produced by `scripts/build-app.sh`: `bin/yt-dlp/yt-dlp_macos`, and the pinned tag
    /// in `bin/yt-dlp-version`.
    public init(resourcesDirectory: URL) {
        let bin = resourcesDirectory.appendingPathComponent("bin", isDirectory: true)
        let tag = (try? String(contentsOf: bin.appendingPathComponent("yt-dlp-version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            executable: bin.appendingPathComponent("yt-dlp/yt-dlp_macos"),
            version: tag.flatMap(YtDlpVersion.init)
        )
    }
}

/// One runnable yt-dlp.
public struct YtDlpCopy: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        case downloaded
        case bundled
    }

    public var version: YtDlpVersion?
    public var executable: URL
    public var origin: Origin

    public init(version: YtDlpVersion?, executable: URL, origin: Origin) {
        self.version = version
        self.executable = executable
        self.origin = origin
    }
}

/// The downloaded yt-dlp copies and which one is in use.
///
/// Layout (ADR 0002): `<root>/<tag>/yt-dlp_macos` (+ `_internal/`), `<root>/state.json`,
/// and short-lived `<root>/.staging-*` directories. Every copy that is not the active or the
/// previous one is deleted. Not thread-safe: the caller runs one update at a time.
public struct YtDlpInstallations: Sendable {
    public static let executableName = "yt-dlp_macos"

    public let root: URL
    public let bundled: BundledYtDlp

    public init(root: URL, bundled: BundledYtDlp) {
        self.root = root
        self.bundled = bundled
    }

    /// `~/Library/Application Support/<bundle-id>/yt-dlp`.
    public static func defaultRoot(bundleIdentifier: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("yt-dlp", isDirectory: true)
    }

    private var stateFile: URL { root.appendingPathComponent("state.json") }

    // MARK: State

    /// The stored pointer; a missing or unreadable file counts as nothing downloaded.
    public func readState() -> YtDlpState {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(YtDlpState.self, from: data)
        else { return YtDlpState() }
        return state
    }

    /// Writes the pointer atomically (temp file + rename).
    public func writeState(_ state: YtDlpState) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateFile, options: .atomic)
    }

    // MARK: Which copy runs

    /// The copy to run: the downloaded active one if it exists and is newer than the bundled one,
    /// else the bundled one. Reads only; see `prepareAtLaunch()` for the cleanup.
    public func current() -> YtDlpCopy {
        fallbackChain()[0]
    }

    /// Copies to try in order when one fails to launch: active, previous, bundled.
    /// Downloaded copies that are missing or not newer than the bundled one are left out.
    /// Always ends with the bundled copy.
    public func fallbackChain() -> [YtDlpCopy] {
        let state = readState()
        var chain = [state.active, state.previous].compactMap { tag in tag.flatMap(usableDownload) }
        chain.append(YtDlpCopy(version: bundled.version, executable: bundled.executable, origin: .bundled))
        return chain
    }

    /// Run once at launch: forgets downloads that are missing or older than the bundled copy,
    /// deletes them and any leftover staging or unreferenced directory, and returns `current()`.
    @discardableResult
    public func prepareAtLaunch() throws -> YtDlpCopy {
        var state = readState()
        if let tag = state.active, !keepsDownload(tag) { state.active = nil }
        if let tag = state.previous, !keepsDownload(tag) { state.previous = nil }
        if FileManager.default.fileExists(atPath: root.path) {
            if state != readState() { try writeState(state) }
            try removeEverything(except: state)
        }
        return current()
    }

    // MARK: Installing

    /// A fresh empty directory inside the root (same volume, so `install` can rename atomically).
    public func makeStagingDirectory() throws -> URL {
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Moves a verified, smoke-tested staging directory into place as `version`, makes it active,
    /// keeps the old active as previous, clears the Roll back pin, and deletes everything else.
    public func install(_ staging: URL, as version: YtDlpVersion) throws -> YtDlpCopy {
        let destination = directory(for: version.tag)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            // Re-installing a tag that is kept as previous (e.g. after Roll back): replace it.
            let trash = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try fileManager.moveItem(at: destination, to: trash)
            try? fileManager.removeItem(at: trash)
        }
        try fileManager.moveItem(at: staging, to: destination)

        let old = readState()
        let previous = old.active == version.tag ? old.previous : old.active
        let state = YtDlpState(active: version.tag, previous: previous, pinned: false)
        try writeState(state)
        try removeEverything(except: state)
        return YtDlpCopy(version: version, executable: executable(in: destination), origin: .downloaded)
    }

    // MARK: Helpers

    private func directory(for tag: String) -> URL {
        root.appendingPathComponent(tag, isDirectory: true)
    }

    private func executable(in directory: URL) -> URL {
        directory.appendingPathComponent(Self.executableName)
    }

    /// A downloaded copy worth running: on disk and newer than the bundled one.
    private func usableDownload(_ tag: String) -> YtDlpCopy? {
        guard keepsDownload(tag), let version = YtDlpVersion(tag) else { return nil }
        return YtDlpCopy(version: version, executable: executable(in: directory(for: tag)), origin: .downloaded)
    }

    private func keepsDownload(_ tag: String) -> Bool {
        guard let version = YtDlpVersion(tag),
              FileManager.default.fileExists(atPath: executable(in: directory(for: tag)).path)
        else { return false }
        guard let floor = bundled.version else { return true }
        return version > floor
    }

    private func removeEverything(except state: YtDlpState) throws {
        let keep = Set([state.active, state.previous].compactMap { $0 } + ["state.json"])
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where !keep.contains(name) {
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }
}

/// The yt-dlp copy downloads run with right now, shared between the updater (which changes it
/// at launch and after an update) and `YtDlpRunner` (which reads it at the start of each run).
public final class YtDlpSelection: Sendable {
    private let state: OSAllocatedUnfairLock<YtDlpCopy>

    public init(_ copy: YtDlpCopy) {
        state = OSAllocatedUnfairLock(initialState: copy)
    }

    public var copy: YtDlpCopy { state.withLock { $0 } }

    public func select(_ copy: YtDlpCopy) {
        state.withLock { $0 = copy }
    }
}
