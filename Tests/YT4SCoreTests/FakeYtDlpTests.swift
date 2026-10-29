import Foundation
import Testing
@testable import YT4SCore

/// Drives the fake yt-dlp fixture through the same invocation path the app uses.
@Suite struct FakeYtDlpTests {
    @Test func successDownloadsFileAndPrintsFinalPath() async throws {
        let fake = try FakeYtDlp()
        let result = try await fake.run(
            [
                "--print", "after_move:%(id)s\t%(filepath)s",
                "-P", fake.downloadFolder.path,
                "-o", "%(title)s.%(ext)s",
                "https://www.youtube.com/watch?v=abc123",
            ],
            scenario: "success"
        )

        #expect(result.termination == .exited(0))
        let expectedPath = fake.downloadFolder.appendingPathComponent("Fake Video abc123.mp4").path
        #expect(result.stdoutLines.contains("abc123\t\(expectedPath)"))
        #expect(FileManager.default.fileExists(atPath: expectedPath))
    }
}
