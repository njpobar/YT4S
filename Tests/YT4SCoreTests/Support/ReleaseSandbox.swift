import Foundation
@testable import YT4SCore

/// A throwaway git repo + bare `origin` holding the real `scripts/release.sh`, so the release
/// script runs end to end without touching GitHub, the real repo, or a real build.
///
/// Stubbed: `swift` and `gh` (PATH stubs that log their argv), `scripts/build-app.sh` (writes a
/// tiny unsigned `build/YT4S.app` from the version and build number it is handed) and
/// `scripts/make-dmg.sh` (hdiutil takes ~10 s; `MakeDmgTests` covers the real one).
/// Real: git (against the local bare remote), ditto, plutil.
struct ReleaseSandbox {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    let root: URL
    let repo: URL
    let remote: URL
    let stubBin: URL
    let ghLog: URL
    let swiftLog: URL

    /// - Parameter version: contents of the sandbox's committed `VERSION` file.
    init(version: String = "0.1.0") async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-release-\(UUID().uuidString)", isDirectory: true)
        repo = root.appendingPathComponent("repo", isDirectory: true)
        remote = root.appendingPathComponent("remote.git", isDirectory: true)
        stubBin = root.appendingPathComponent("stub-bin", isDirectory: true)
        ghLog = root.appendingPathComponent("gh.log")
        swiftLog = root.appendingPathComponent("swift.log")

        let fm = FileManager.default
        try fm.createDirectory(at: repo.appendingPathComponent("scripts/lib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stubBin, withIntermediateDirectories: true)

        let real = Self.repoRoot
        for path in ["scripts/release.sh","scripts/lib/deps.sh", "scripts/lib/version.sh", ".gitignore"] {
            try fm.copyItem(at: real.appendingPathComponent(path), to: repo.appendingPathComponent(path))
        }
        try write("\(version)\n", to: repo.appendingPathComponent("VERSION"))
        try write(Self.buildAppStub, to: repo.appendingPathComponent("scripts/build-app.sh"), executable: true)
        try write(Self.makeDmgStub, to: repo.appendingPathComponent("scripts/make-dmg.sh"), executable: true)
        try write(Self.logStub(log: "YT4S_STUB_SWIFT_LOG", exit: "YT4S_STUB_SWIFT_EXIT"), to: stubBin.appendingPathComponent("swift"), executable: true)
        try write(Self.logStub(log: "YT4S_STUB_GH_LOG", exit: "YT4S_STUB_GH_EXIT"), to: stubBin.appendingPathComponent("gh"), executable: true)

        try await shell("""
            set -e
            git init -q --bare -b main "\(remote.path)"
            cd "\(repo.path)"
            git init -q -b main
            git add -A
            git commit -q -m "Initial"
            git remote add origin "\(remote.path)"
            git push -q -u origin main
            """)
    }

    /// Runs `scripts/release.sh` with `arguments`, feeding `input` on stdin (the confirm prompt).
    func release(_ arguments: [String], input: String = "", environment: [String: String] = [:]) async throws -> SubprocessResult {
        let quoted = arguments.map { "'\($0)'" }.joined(separator: " ")
        return try await shell("printf '%s' '\(input)' | scripts/release.sh \(quoted)", environment: environment)
    }

    /// Runs bash in the sandbox repo with the stubs first on PATH.
    @discardableResult
    func shell(_ script: String, environment: [String: String] = [:]) async throws -> SubprocessResult {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(stubBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        env["YT4S_STUB_GH_LOG"] = ghLog.path
        env["YT4S_STUB_SWIFT_LOG"] = swiftLog.path
        env["GIT_AUTHOR_NAME"] = "Test"
        env["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
        env["GIT_COMMITTER_NAME"] = "Test"
        env["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env.merge(environment) { _, new in new }
        return try await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "cd \"\(repo.path)\" && \(script)"],
            environment: env
        )
    }

    /// Output of a git command run in the sandbox repo (or in `--git-dir` of the remote).
    func git(_ arguments: String) async throws -> String {
        try await shell("git \(arguments)").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteGit(_ arguments: String) async throws -> String {
        try await shell("git --git-dir=\"\(remote.path)\" \(arguments)").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each logged invocation of the stub, as an argv array.
    func invocations(_ log: URL) throws -> [[String]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\u{1}").map { record in
            record.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    func file(_ relativePath: String) -> URL {
        repo.appendingPathComponent(relativePath)
    }

    private func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// Logs argv (NUL-separated, records separated by \x01) and exits with $EXIT_VAR (default 0).
    private static func logStub(log: String, exit: String) -> String {
        """
        #!/bin/bash
        { printf '%s\\0' "$@"; printf '\\001'; } >> "$\(log)"
        exit "${\(exit):-0}"
        """
    }

    /// Writes a placeholder at the DMG path it is given.
    private static let makeDmgStub = """
        #!/bin/bash
        set -euo pipefail
        [ -d "$1" ]
        echo "stub dmg of $1 named $3" > "$2"
        """

    /// Stands in for the real build: writes an app whose Info.plist carries the version and build
    /// number release.sh handed over, unless YT4S_STUB_PLIST_VERSION overrides the version.
    private static let buildAppStub = """
        #!/bin/bash
        set -euo pipefail
        root="$(cd "$(dirname "$0")/.." && pwd)"
        app="$root/build/YT4S.app"
        rm -rf "$app"
        mkdir -p "$app/Contents/MacOS"
        printf '#!/bin/sh\\n' > "$app/Contents/MacOS/YT4S"
        chmod 755 "$app/Contents/MacOS/YT4S"
        plutil -create xml1 "$app/Contents/Info.plist"
        plutil -insert CFBundleShortVersionString -string "${YT4S_STUB_PLIST_VERSION:-$YT4S_VERSION}" "$app/Contents/Info.plist"
        plutil -insert CFBundleVersion -string "$YT4S_BUILD_NUMBER" "$app/Contents/Info.plist"
        """
}
