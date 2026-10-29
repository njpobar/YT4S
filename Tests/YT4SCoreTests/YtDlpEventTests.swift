import Foundation
import Testing
@testable import YT4SCore

/// Parsing of the machine-readable lines YT4S asks yt-dlp to print.
/// Fixtures under `Fixtures/yt-dlp-output/` were captured from the real bundled yt-dlp
/// (2026.10.26.220202) using exactly the templates in `YtDlpOutputTemplates`.
@Suite struct YtDlpEventTests {
    @Test func parsesTheVideoLineOfAMergedDownload() throws {
        let line = try Fixture.lines("merged-video-audio")[0]

        #expect(YtDlpEvent(line: line) == .video(VideoInfo(
            id: "jNQXAC9IVRw",
            title: "Me at the zoo",
            formatIDs: ["395", "251"],
            partSizes: [223779, 252182]
        )))
    }

    @Test func parsesTheVideoLineOfASingleFormatDownload() throws {
        let line = try Fixture.lines("progressive")[0]

        #expect(YtDlpEvent(line: line) == .video(VideoInfo(
            id: "jNQXAC9IVRw",
            title: "Me at the zoo",
            formatIDs: ["18"],
            partSizes: [635110]
        )))
    }

    @Test func parsesAVideoLineWithUnknownSize() throws {
        let line = try Fixture.lines("hls-fragments")[0]

        #expect(YtDlpEvent(line: line) == .video(VideoInfo(
            id: "jNQXAC9IVRw", title: "Me at the zoo", formatIDs: ["604"], partSizes: [nil]
        )))
    }

    @Test func parsesAProgressLineWithKnownTotal() throws {
        let line = try Fixture.lines("merged-video-audio")[3]

        #expect(YtDlpEvent(line: line) == .progress(PartProgress(
            videoID: "jNQXAC9IVRw",
            formatID: "395",
            status: .downloading,
            downloadedBytes: 7168,
            totalBytes: 223779,
            totalBytesEstimate: nil,
            speed: 1359166.8658227848,
            eta: 0,
            fragmentIndex: nil,
            fragmentCount: nil
        )))
    }

    @Test func parsesAFragmentedProgressLineWithOnlyAnEstimate() throws {
        let line = try Fixture.lines("hls-fragments")[2]

        #expect(YtDlpEvent(line: line) == .progress(PartProgress(
            videoID: "jNQXAC9IVRw",
            formatID: "604",
            status: .downloading,
            downloadedBytes: 712,
            totalBytes: nil,
            totalBytesEstimate: 4272,
            speed: 4256.647634009427,
            eta: nil,
            fragmentIndex: 1,
            fragmentCount: 3
        )))
    }

    @Test func parsesTheFinishedFileLine() throws {
        let line = try #require(Fixture.lines("merged-video-audio").last)

        #expect(YtDlpEvent(line: line) == .file(videoID: "jNQXAC9IVRw", path: "/Users/sarah/Downloads/YT4S/Me at the zoo.mp4"))
    }

    @Test func everyCapturedLineIsUnderstood() throws {
        for name in ["merged-video-audio", "progressive", "hls-fragments"] {
            for line in try Fixture.lines(name) {
                #expect(YtDlpEvent(line: line) != nil, "unparsed line in \(name): \(line)")
            }
        }
    }

    @Test func ignoresNormalYtDlpOutput() {
        #expect(YtDlpEvent(line: "[youtube] jNQXAC9IVRw: Downloading webpage") == nil)
        #expect(YtDlpEvent(line: "[download]  50.0% of   10.00MiB at    1.00MiB/s ETA 00:05") == nil)
        #expect(YtDlpEvent(line: "") == nil)
    }

    @Test func titlesKeepTabsQuotesAndUnicode() {
        let line = "YT4S-VIDEO\tabc\t18\t[]\t100\t\"A \\\"quoted\\\"\\ttitle \u{00e9}\""

        #expect(YtDlpEvent(line: line) == .video(VideoInfo(
            id: "abc", title: "A \"quoted\"\ttitle \u{00e9}", formatIDs: ["18"], partSizes: [100]
        )))
    }
}

enum Fixture {
    static func lines(_ name: String) throws -> [String] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "stdout", subdirectory: "Fixtures/yt-dlp-output") else {
            throw FixtureError.missing("Fixtures/yt-dlp-output/\(name).stdout")
        }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }
}
