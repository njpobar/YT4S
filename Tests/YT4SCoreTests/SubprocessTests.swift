import Foundation
import Testing
@testable import YT4SCore

@Suite struct SubprocessTests {
    /// Cancel can arrive before the child is launched (e.g. Cancel pressed right as a video
    /// starts). The child must still never get to do its work.
    @Test func cancellingBeforeLaunchNeverLetsTheChildRun() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("yt4s-subprocess-\(UUID().uuidString)")
        let task = Task {
            try await Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 0.3; touch \"$0\"", marker.path]
            )
        }
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(600))

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
