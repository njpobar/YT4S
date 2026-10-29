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

    @Test func downloadsByVideoIDIntoTheIncompleteFolderAndReportsNamingDetails() {
        let argv = DownloadArguments.arguments(for: request)

        #expect(argv.containsSequence(["-P", "/Users/sarah/Downloads/YT4S"]))
        #expect(argv.containsSequence(["-o", ".yt4s-incomplete/%(id)s.%(ext)s"]))
        #expect(argv.containsSequence(["--print", YtDlpOutputTemplates.details]))
    }

    private func arguments(_ format: Format, _ quality: QualityPreset = .best) -> [String] {
        var request = request
        request.options.format = format
        request.options.quality = quality
        return DownloadArguments.arguments(for: request)
    }

    // Every Video preset prefers QuickTime-playable H.264 + AAC (M1 cannot hardware-decode AV1,
    // QuickTime cannot play VP9 / Opus), falls back to any codec, and merges into an MP4.
    private let quickTimeFriendlySort = ["-S", "vcodec:h264,res,acodec:aac"]

    @Test func videoBestPrefersH264AndAACAtTheHighestResolution() {
        let argv = arguments(.video, .best)

        #expect(argv.containsSequence(["-f", "bv*+ba/b"]))
        #expect(argv.containsSequence(quickTimeFriendlySort))
        #expect(argv.containsSequence(["--merge-output-format", "mp4"]))
    }

    @Test func video1080pCapsHeightAndFallsBackBelowTheCap() {
        let argv = arguments(.video, .p1080)

        #expect(argv.containsSequence(["-f", "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b"]))
        #expect(argv.containsSequence(quickTimeFriendlySort))
        #expect(argv.containsSequence(["--merge-output-format", "mp4"]))
    }

    @Test func video720pCapsHeightAndFallsBackBelowTheCap() {
        let argv = arguments(.video, .p720)

        #expect(argv.containsSequence(["-f", "bv*[height<=720]+ba/b[height<=720]/bv*+ba/b"]))
        #expect(argv.containsSequence(quickTimeFriendlySort))
        #expect(argv.containsSequence(["--merge-output-format", "mp4"]))
    }

    @Test func videoDoesNotExtractAudio() {
        #expect(!arguments(.video).contains("-x"))
    }

    @Test func mp3Is320kbpsWithCoverArtAndMetadata() {
        let argv = arguments(.mp3)

        #expect(argv.containsSequence(["-f", "ba/b"]))
        #expect(argv.containsSequence(["-x", "--audio-format", "mp3", "--audio-quality", "320K"]))
        #expect(argv.containsSequence(["--embed-thumbnail", "--convert-thumbnails", "jpg"]))
        #expect(argv.contains("--embed-metadata"))
        #expect(!argv.contains("--merge-output-format"))
    }

    @Test func mp3IgnoresTheQualityPreset() {
        #expect(arguments(.mp3, .p720) == arguments(.mp3, .best))
    }

    @Test func neverAddsSubtitlesChaptersOrSponsorBlock() {
        for format in Format.allCases {
            for quality in QualityPreset.allCases {
                let argv = arguments(format, quality)
                #expect(!argv.contains { $0.contains("sub") || $0.contains("sponsorblock") || $0 == "--embed-chapters" })
                #expect(!argv.contains("--split-chapters"))
            }
        }
        // --embed-metadata would also embed chapters unless told not to.
        #expect(arguments(.mp3).contains("--no-embed-chapters"))
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
