import CryptoKit
import Foundation
@testable import YT4SCore

/// A throwaway git repo + bare `origin` holding the real `scripts/release.sh`, so the release
/// script runs end to end without touching GitHub, the real repo, or a real build.
///
/// Stubbed: `swift` and `gh` (PATH stubs that log their argv), `scripts/build-app.sh` (writes a
/// tiny unsigned `build/YT4S.app` from the version and build number it is handed) and
/// `scripts/make-dmg.sh` (hdiutil takes ~10 s; `MakeDmgTests` covers the real one).
/// Sparkle: `$YT4S_SPARKLE_BIN/sign_update` is the real one, handed a throwaway EdDSA key file
/// (never the login Keychain); `generate_keys -p` is a stub that prints that key's public half
/// (`YT4S_STUB_KEYCHAIN_KEY` overrides it, `YT4S_STUB_NO_KEYCHAIN_KEY=1` makes the Keychain empty).
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
    let sparkleBin: URL
    /// The throwaway signing key; its public half is committed as config/sparkle-public-key.
    let signingKey = Curve25519.Signing.PrivateKey()
    var publicKey: String { signingKey.publicKey.rawRepresentation.base64EncodedString() }

    /// - Parameter version: contents of the sandbox's committed `VERSION` file.
    /// - Parameter configuredKey: committed config/sparkle-public-key value; default the test key's.
    init(version: String = "0.1.0", configuredKey: String? = nil) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-release-\(UUID().uuidString)", isDirectory: true)
        repo = root.appendingPathComponent("repo", isDirectory: true)
        remote = root.appendingPathComponent("remote.git", isDirectory: true)
        stubBin = root.appendingPathComponent("stub-bin", isDirectory: true)
        ghLog = root.appendingPathComponent("gh.log")
        swiftLog = root.appendingPathComponent("swift.log")
        sparkleBin = root.appendingPathComponent("sparkle-bin", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: repo.appendingPathComponent("scripts/lib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stubBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: sparkleBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("config"), withIntermediateDirectories: true)

        let real = Self.repoRoot
        for path in [
            "scripts/release.sh", "scripts/write-appcast.sh",
            "scripts/lib/common.sh", "scripts/lib/version.sh", "scripts/lib/sparkle.sh", ".gitignore",
        ] {
            try fm.copyItem(at: real.appendingPathComponent(path), to: repo.appendingPathComponent(path))
        }
        try write("\(version)\n", to: repo.appendingPathComponent("VERSION"))
        try write(Self.buildAppStub, to: repo.appendingPathComponent("scripts/build-app.sh"), executable: true)
        try write(Self.makeDmgStub, to: repo.appendingPathComponent("scripts/make-dmg.sh"), executable: true)
        try write(Self.swiftStub, to: stubBin.appendingPathComponent("swift"), executable: true)
        try write(Self.logStub(log: "YT4S_STUB_GH_LOG", exit: "YT4S_STUB_GH_EXIT"), to: stubBin.appendingPathComponent("gh"), executable: true)

        let keyFile = root.appendingPathComponent("sparkle-private-key")
        try write(signingKey.rawRepresentation.base64EncodedString(), to: keyFile)
        try write("# test key\n\(configuredKey ?? publicKey)\n", to: repo.appendingPathComponent("config/sparkle-public-key"))
        try write(Self.signUpdateWrapper(keyFile: keyFile), to: sparkleBin.appendingPathComponent("sign_update"), executable: true)
        try write(Self.generateKeysStub(publicKey: publicKey), to: sparkleBin.appendingPathComponent("generate_keys"), executable: true)

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
        env[LiveTests.variable] = nil
        env["PATH"] = "\(stubBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        env["YT4S_STUB_GH_LOG"] = ghLog.path
        env["YT4S_STUB_SWIFT_LOG"] = swiftLog.path
        env["YT4S_SPARKLE_BIN"] = sparkleBin.path
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

    /// `swift`: logs argv like `logStub`, prefixed with `YT4S_LIVE_APP=<value>` when that is set
    /// (the live contract test run). That run fails with 66 if the app is not built yet, else
    /// writes its `--xunit-output` report (two tests; `YT4S_STUB_LIVE_TEST_RESULT=skipped|none`
    /// for a skipped or empty run) and exits with $YT4S_STUB_LIVE_TEST_EXIT.
    /// Every other run exits with $YT4S_STUB_SWIFT_EXIT.
    private static let swiftStub = """
        #!/bin/bash
        {
          [ -z "${YT4S_LIVE_APP:-}" ] || printf 'YT4S_LIVE_APP=%s\\0' "$YT4S_LIVE_APP"
          printf '%s\\0' "$@"; printf '\\001'
        } >> "$YT4S_STUB_SWIFT_LOG"
        if [ -n "${YT4S_LIVE_APP:-}" ]; then
          [ -d "$YT4S_LIVE_APP" ] || { echo "stub swift: no app at $YT4S_LIVE_APP" >&2; exit 66; }
          while [ $# -gt 0 ] && [ "$1" != --xunit-output ]; do shift; done
          if [ $# -gt 1 ]; then
            case "${YT4S_STUB_LIVE_TEST_RESULT:-ran}" in
              ran) result='' ;;
              skipped) result='<skipped>not enabled</skipped>' ;;
            esac
            if [ "${YT4S_STUB_LIVE_TEST_RESULT:-}" = none ]; then
              printf '<testsuites><testsuite tests="0"></testsuite></testsuites>' > "$2"
            else
              printf '<testsuites><testsuite><testcase name="video()">%s</testcase><testcase name="mp3()">%s</testcase></testsuite></testsuites>' "$result" "$result" > "$2"
            fi
          fi
          exit "${YT4S_STUB_LIVE_TEST_EXIT:-0}"
        fi
        exit "${YT4S_STUB_SWIFT_EXIT:-0}"
        """

    /// Sparkle's SwiftPM artifact in this checkout (resolved by `swift test`).
    static let realSparkleBin = repoRoot.appendingPathComponent(".build/artifacts/sparkle/Sparkle/bin")

    /// The real sign_update, always with the throwaway key file instead of the Keychain.
    private static func signUpdateWrapper(keyFile: URL) -> String {
        """
        #!/bin/bash
        exec "\(realSparkleBin.path)/sign_update" --ed-key-file "\(keyFile.path)" "$@"
        """
    }

    /// `generate_keys -p` as if the login Keychain held the sandbox key (or none, or another).
    private static func generateKeysStub(publicKey: String) -> String {
        """
        #!/bin/bash
        [ "$*" = "-p" ] || { echo "stub generate_keys only supports -p, got: $*" >&2; exit 64; }
        if [ "${YT4S_STUB_NO_KEYCHAIN_KEY:-}" = 1 ]; then
          echo "ERROR! There is no existing EdDSA key in your keychain." >&2
          exit 1
        fi
        echo "${YT4S_STUB_KEYCHAIN_KEY:-\(publicKey)}"
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
