import Foundation
import Testing
@testable import YT4SCore

/// `scripts/make-dmg.sh` with the real hdiutil (~10 s: create + verify + attach).
@Suite struct MakeDmgTests {
    @Test func dmgHoldsTheAppNextToAnApplicationsAlias() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-dmg-\(UUID().uuidString)", isDirectory: true)
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/make-dmg.sh").path

        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", """
                set -e
                mkdir -p "\(root.path)"
                cd "\(root.path)"
                mkdir -p YT4S.app/Contents/MacOS
                echo app > YT4S.app/Contents/MacOS/YT4S
                "\(script)" YT4S.app out/YT4S-1.2.3.dmg "YT4S 1.2.3"
                hdiutil attach -quiet -readonly -nobrowse -mountpoint mnt out/YT4S-1.2.3.dmg
                trap 'hdiutil detach -quiet mnt' EXIT
                ls mnt
                readlink mnt/Applications
                cat mnt/YT4S.app/Contents/MacOS/YT4S
                diskutil info mnt | sed -n 's/^ *Volume Name: *//p'
                """]
        )

        #expect(result.termination == .exited(0), "\(result.stdout)\n\(result.stderr)")
        #expect(result.stdoutLines == ["Applications", "YT4S.app", "/Applications", "app", "YT4S 1.2.3"])
    }
}
