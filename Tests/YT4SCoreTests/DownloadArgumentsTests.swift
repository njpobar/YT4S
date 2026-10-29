import Foundation
import Testing
@testable import YT4SCore

/// The argv YT4S hands yt-dlp for one Queue item (after the mandatory flags).
@Suite struct DownloadArgumentsTests {
    private let request = DownloadRequest(
        url: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
        downloadFolder: URL(fileURLWithPath: "/Users/sarah/Downloads/YT4S", isDirectory: true),
        options: .default
    )

    @Test func defaultOptionsAreVideoBestTitle() {
        #expect(DownloadOptions.default == DownloadOptions(format: .video, quality: .best, naming: .title))
    }

    @Test func savesIntoTheDownloadFolderNamedByTitle() {
        let argv = DownloadArguments.arguments(for: request)

        #expect(argv.containsSequence(["-P", "/Users/sarah/Downloads/YT4S"]))
        #expect(argv.containsSequence(["-o", "%(title)s.%(ext)s"]))
    }

    @Test func videoBestPicksTheBestStreamsAndMergesToMP4() {
        let argv = DownloadArguments.arguments(for: request)

        #expect(argv.containsSequence(["-f", "bv*+ba/b"]))
        #expect(argv.containsSequence(["--merge-output-format", "mp4"]))
    }

    @Test func readsProgressAndMetadataOnlyThroughYT4STemplates() {
        let argv = DownloadArguments.arguments(for: request)

        #expect(argv.containsSequence(["--progress-template", YtDlpOutputTemplates.progress]))
        #expect(argv.containsSequence(["--print", YtDlpOutputTemplates.video]))
        #expect(argv.containsSequence(["--print", YtDlpOutputTemplates.file]))
        // --print implies --quiet, which hides progress unless --progress is given; one line per tick.
        #expect(argv.contains("--progress"))
        #expect(argv.contains("--newline"))
    }

    @Test func downloadsOnlyTheLinkedVideoAndTreatsTheURLAsAnOperand() {
        let argv = DownloadArguments.arguments(for: request)

        #expect(argv.contains("--no-playlist"))
        #expect(argv.suffix(2) == ["--", "https://www.youtube.com/watch?v=jNQXAC9IVRw"])
    }
}

extension Array where Element: Equatable {
    func containsSequence(_ sequence: [Element]) -> Bool {
        guard sequence.count <= count else { return false }
        return (0...(count - sequence.count)).contains { Array(self[$0..<($0 + sequence.count)]) == sequence }
    }
}
