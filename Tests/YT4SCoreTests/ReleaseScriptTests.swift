import CryptoKit
import Foundation
import Testing
@testable import YT4SCore

/// `scripts/release.sh` end to end in a sandbox repo (see `ReleaseSandbox`).
@Suite struct ReleaseScriptTests {
    @Test func releasesADraftWithZipAndDmgAfterConfirmation() async throws {
        let sandbox = try await ReleaseSandbox(version: "0.1.0")

        let result = try await sandbox.release(["0.2.0"], input: "0.2.0\n")

        #expect(result.termination == .exited(0), "\(result.stdout)\n\(result.stderr)")

        // VERSION bump committed, and main + tag pushed together.
        let tagged = try await sandbox.remoteGit("rev-parse v0.2.0^{commit}")
        #expect(try await sandbox.remoteGit("rev-parse main") == tagged)
        #expect(try await sandbox.remoteGit("show v0.2.0:VERSION") == "0.2.0")

        // swift test ran before anything was built.
        #expect(try sandbox.invocations(sandbox.swiftLog).first?.prefix(1) == ["test"])

        // One draft release with exactly the zip, its appcast and the DMG.
        let create = try #require(try releaseCreations(sandbox).first)
        #expect(try releaseCreations(sandbox).count == 1)
        #expect(create[2] == "v0.2.0")
        #expect(create.contains("--draft"))
        #expect(create.contains("--verify-tag"))
        let assets = create.filter { $0.hasPrefix("/") }.map { ($0 as NSString).lastPathComponent }
        #expect(assets.sorted() == ["YT4S-0.2.0.dmg", "YT4S-0.2.0.zip", "appcast.xml"])

        // The zipped app carries the version, and the tagged commit's count as build number.
        let commitCount = try await sandbox.remoteGit("rev-list --count v0.2.0")
        #expect(try await zippedVersions(sandbox, "0.2.0") == ["0.2.0", commitCount])
    }

    @Test func appcastHasOneSignedEntryForTheZipOnTheTaggedRelease() async throws {
        let sandbox = try await ReleaseSandbox(version: "0.1.0")

        let result = try await sandbox.release(["0.2.0"], input: "0.2.0\n")
        #expect(result.termination == .exited(0), "\(result.stdout)\n\(result.stderr)")

        let appcast = try XMLDocument(contentsOf: sandbox.file("dist/appcast.xml"))
        let items = try appcast.nodes(forXPath: "/rss/channel/item")
        #expect(items.count == 1, "a single entry, no deltas")
        #expect(try appcast.nodes(forXPath: "//*[local-name()='deltas']").isEmpty)

        let item = try #require(items.first as? XMLElement)
        #expect(text(item, "sparkle:shortVersionString") == "0.2.0")
        #expect(text(item, "sparkle:version") == (try await sandbox.remoteGit("rev-list --count v0.2.0")))
        #expect(text(item, "sparkle:minimumSystemVersion") == "14.0")

        let enclosure = try #require(item.elements(forName: "enclosure").first)
        #expect(enclosure.attribute(forName: "url")?.stringValue
            == "https://github.com/njpobar/YT4S/releases/download/v0.2.0/YT4S-0.2.0.zip")
        let zip = try Data(contentsOf: sandbox.file("dist/YT4S-0.2.0.zip"))
        #expect(enclosure.attribute(forName: "length")?.stringValue == String(zip.count))

        // The EdDSA signature verifies against the public key the app ships with.
        let signature = try #require(enclosure.attribute(forName: "sparkle:edSignature")?.stringValue)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try #require(Data(base64Encoded: sandbox.publicKey)))
        #expect(publicKey.isValidSignature(try #require(Data(base64Encoded: signature)), for: zip))
        #expect(!publicKey.isValidSignature(try #require(Data(base64Encoded: signature)), for: zip + Data([0])))
    }

    @Test func refusesWithoutTheSigningKeyInTheKeychain() async throws {
        let sandbox = try await ReleaseSandbox()

        try await expectRefused(
            sandbox, ["0.2.0"],
            environment: ["YT4S_STUB_NO_KEYCHAIN_KEY": "1"],
            because: "no Sparkle signing key in your login Keychain; do the one-time setup in README.md (Signing key for app updates)"
        )
    }

    @Test func refusesWhenTheKeychainKeyIsNotTheOneTheAppTrusts() async throws {
        let sandbox = try await ReleaseSandbox()

        try await expectRefused(
            sandbox, ["0.2.0"],
            environment: ["YT4S_STUB_KEYCHAIN_KEY": "b3RoZXI="],
            because: "the Sparkle key in your login Keychain (b3RoZXI=) does not match config/sparkle-public-key (\(sandbox.publicKey))"
        )
    }

    @Test func refusesWhileNoPublicKeyIsCheckedIn() async throws {
        let sandbox = try await ReleaseSandbox(configuredKey: "")

        try await expectRefused(sandbox, ["0.2.0"], because: "config/sparkle-public-key is empty")
    }

    @Test func releasingTheVersionAlreadyInVersionFileTagsHeadWithoutABumpCommit() async throws {
        let sandbox = try await ReleaseSandbox(version: "0.3.0")
        let head = try await sandbox.git("rev-parse HEAD")

        let result = try await sandbox.release(["0.3.0"], input: "0.3.0\n")

        #expect(result.termination == .exited(0), "\(result.stdout)\n\(result.stderr)")
        #expect(try await sandbox.remoteGit("rev-parse v0.3.0^{commit}") == head)
        #expect(try await zippedVersions(sandbox, "0.3.0") == ["0.3.0", "1"])
    }

    @Test func dryRunBuildsTheAssetsButNeverTagsOrTalksToGitHub() async throws {
        let sandbox = try await ReleaseSandbox(version: "0.1.0")
        let head = try await sandbox.git("rev-parse HEAD")

        let result = try await sandbox.release(["--dry-run", "0.2.0"])

        #expect(result.termination == .exited(0), "\(result.stdout)\n\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: sandbox.file("dist/YT4S-0.2.0.zip").path))
        #expect(FileManager.default.fileExists(atPath: sandbox.file("dist/YT4S-0.2.0.dmg").path))
        #expect(FileManager.default.fileExists(atPath: sandbox.file("dist/appcast.xml").path))
        try await expectNothingPublished(sandbox, head: head)
        #expect(try sandbox.invocations(sandbox.ghLog).isEmpty)
        #expect(result.stdout.contains("gh release create v0.2.0 --draft"))
    }

    @Test func notConfirmingTheChecklistPublishesNothing() async throws {
        let sandbox = try await ReleaseSandbox(version: "0.1.0")
        let head = try await sandbox.git("rev-parse HEAD")

        let result = try await sandbox.release(["0.2.0"], input: "y\n")

        #expect(result.termination == .exited(1))
        #expect(result.stderr.contains("not confirmed"))
        try await expectNothingPublished(sandbox, head: head)
        #expect(try await sandbox.shell("cat VERSION").stdout == "0.1.0\n")
    }

    @Test func refusesADirtyTree() async throws {
        let sandbox = try await ReleaseSandbox()
        try await sandbox.shell("touch stray.txt")

        try await expectRefused(sandbox, ["0.2.0"], because: "working tree is not clean")
    }

    @Test func refusesABranchOtherThanMain() async throws {
        let sandbox = try await ReleaseSandbox()
        try await sandbox.shell("git checkout -q -b feature")

        try await expectRefused(sandbox, ["0.2.0"], because: "releases are cut from main, not 'feature'")
    }

    @Test func refusesAMainThatIsAheadOfOrigin() async throws {
        let sandbox = try await ReleaseSandbox()
        try await sandbox.shell("git commit -q --allow-empty -m unpushed")

        try await expectRefused(sandbox, ["0.2.0"], because: "main is not in sync with origin/main")
    }

    @Test(arguments: [
        ("1.2", "version must be semver X.Y.Z, got '1.2'"),
        ("v1.2.3", "version must be semver X.Y.Z, got 'v1.2.3'"),
        ("01.2.3", "version must be semver X.Y.Z, got '01.2.3'"),
        ("0.0.9", "0.0.9 is older than VERSION (0.1.0)"),
    ])
    func refusesABadVersion(version: String, reason: String) async throws {
        let sandbox = try await ReleaseSandbox(version: "0.1.0")

        try await expectRefused(sandbox, [version], because: reason)
    }

    @Test func refusesAVersionNotNewerThanTheLastRelease() async throws {
        let sandbox = try await ReleaseSandbox(version: "0.1.0")
        try await sandbox.shell("git tag -a v0.5.0 -m old && git push -q origin v0.5.0")

        try await expectRefused(sandbox, ["0.4.0"], because: "0.4.0 is not newer than the last release v0.5.0")
        try await expectRefused(sandbox, ["0.5.0"], because: "tag v0.5.0 already exists")
    }

    @Test func failingSwiftTestStopsTheRelease() async throws {
        let sandbox = try await ReleaseSandbox()
        let head = try await sandbox.git("rev-parse HEAD")

        let result = try await sandbox.release(["0.2.0"], input: "0.2.0\n", environment: ["YT4S_STUB_SWIFT_EXIT": "1"])

        #expect(result.termination != .exited(0))
        #expect(!FileManager.default.fileExists(atPath: sandbox.file("build/YT4S.app").path))
        try await expectNothingPublished(sandbox, head: head)
    }

    @Test func builtAppWithTheWrongVersionStopsTheRelease() async throws {
        let sandbox = try await ReleaseSandbox()
        let head = try await sandbox.git("rev-parse HEAD")

        let result = try await sandbox.release(["0.2.0"], input: "0.2.0\n", environment: ["YT4S_STUB_PLIST_VERSION": "9.9.9"])

        #expect(result.termination == .exited(1))
        #expect(result.stderr.contains("built app is 9.9.9 (2), expected 0.2.0 (2)"))
        try await expectNothingPublished(sandbox, head: head)
    }

    // MARK: - Helpers

    private func text(_ element: XMLElement, _ name: String) -> String? {
        element.elements(forName: name).first?.stringValue
    }

    private func releaseCreations(_ sandbox: ReleaseSandbox) throws -> [[String]] {
        try sandbox.invocations(sandbox.ghLog).filter { $0.prefix(2) == ["release", "create"] }
    }

    /// CFBundleShortVersionString and CFBundleVersion of the app inside dist/YT4S-<version>.zip.
    private func zippedVersions(_ sandbox: ReleaseSandbox, _ version: String) async throws -> [String] {
        try await sandbox.shell("""
            set -e
            out=$(mktemp -d)
            ditto -x -k dist/YT4S-\(version).zip "$out"
            plutil -extract CFBundleShortVersionString raw "$out/YT4S.app/Contents/Info.plist"
            plutil -extract CFBundleVersion raw "$out/YT4S.app/Contents/Info.plist"
            """).stdoutLines
    }

    private func expectRefused(
        _ sandbox: ReleaseSandbox,
        _ arguments: [String],
        environment: [String: String] = [:],
        because reason: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let head = try await sandbox.git("rev-parse HEAD")
        let result = try await sandbox.release(arguments, input: "\(arguments.last ?? "")\n", environment: environment)

        #expect(result.termination == .exited(1), sourceLocation: sourceLocation)
        #expect(result.stderr.contains("error: \(reason)"), "\(result.stderr)", sourceLocation: sourceLocation)
        #expect(try sandbox.invocations(sandbox.swiftLog).isEmpty, "gates ran before preflight passed", sourceLocation: sourceLocation)
        try await expectNothingPublished(sandbox, head: head, sourceLocation: sourceLocation)
    }

    private func expectNothingPublished(
        _ sandbox: ReleaseSandbox,
        head: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        #expect(try releaseCreations(sandbox).isEmpty, sourceLocation: sourceLocation)
        #expect(try await sandbox.git("rev-parse HEAD") == head, "a commit was made", sourceLocation: sourceLocation)
        #expect(try await sandbox.remoteGit("rev-list --count main") == "1", "main was pushed", sourceLocation: sourceLocation)
        #expect(try await sandbox.remoteGit("tag --list v0.2.0 v0.3.0 v0.4.0").isEmpty, "a tag was pushed", sourceLocation: sourceLocation)
        #expect(try await sandbox.git("tag --list v0.2.0 v0.3.0 v0.4.0").isEmpty, "a tag was created", sourceLocation: sourceLocation)
    }
}
