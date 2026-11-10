import Foundation
import Testing
@testable import YT4SCore

/// Where a Snip saves its Snipped copy: next to the original, `<name> (snipped).<ext>`, numbered
/// when that name is taken.
@Suite struct SnippedCopyTests {
    private let folder = URL(fileURLWithPath: "/tmp/YT4S/Playlist", isDirectory: true)

    private func copy(of name: String, snippedCopy: Bool = false, taken: Set<String> = []) -> String {
        SnippedCopy.file(for: folder.appendingPathComponent(name), sourceIsSnippedCopy: snippedCopy) {
            taken.contains($0.lastPathComponent)
        }.lastPathComponent
    }

    @Test func isNamedAfterTheOriginalInTheSameFolder() {
        let original = folder.appendingPathComponent("03 - Talk.mp4")

        #expect(SnippedCopy.file(for: original) { _ in false } == folder.appendingPathComponent("03 - Talk (snipped).mp4"))
    }

    @Test func keepsTheExtension() {
        #expect(copy(of: "Song.mp3") == "Song (snipped).mp3")
    }

    @Test func isNumberedWhenTheNameIsTaken() {
        #expect(copy(of: "Talk.mp4", taken: ["Talk (snipped).mp4"]) == "Talk (snipped) 2.mp4")
        #expect(copy(of: "Talk.mp4", taken: ["Talk (snipped).mp4", "Talk (snipped) 2.mp4"]) == "Talk (snipped) 3.mp4")
    }

    @Test func namesWithDotsKeepEverythingButTheExtension() {
        #expect(copy(of: "v1.2 release.mp4") == "v1.2 release (snipped).mp4")
    }

    /// Snipping the Snipped copy (the original is gone) names the new one after the original.
    @Test func aCopyOfASnippedCopyIsNamedAfterTheOriginal() {
        #expect(copy(of: "Talk (snipped).mp4", snippedCopy: true, taken: ["Talk (snipped).mp4"]) == "Talk (snipped) 2.mp4")
        #expect(copy(of: "Talk (snipped) 2.mp4", snippedCopy: true, taken: ["Talk (snipped) 2.mp4"]) == "Talk (snipped).mp4")
    }

    @Test func aRenamedSnippedCopyIsNamedAfterItsCurrentName() {
        #expect(copy(of: "Best bits.mp4", snippedCopy: true) == "Best bits (snipped).mp4")
    }

    @Test func onlyASnippedCopyLosesItsSuffix() {
        #expect(copy(of: "Talk (snipped).mp4") == "Talk (snipped) (snipped).mp4")
    }
}
