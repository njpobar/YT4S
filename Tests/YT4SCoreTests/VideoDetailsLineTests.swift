import Foundation
import Testing
@testable import YT4SCore

/// The `YT4S-DETAILS` line naming reads once yt-dlp has looked a video up.
/// `details.stdout` was captured from the real bundled yt-dlp (2026.10.26.220202) with exactly
/// `YtDlpOutputTemplates.details` (without its `before_dl:` stage).
@Suite struct VideoDetailsLineTests {
    @Test func parsesTitleChannelAndUploadDate() throws {
        let lines = try Fixture.lines("details")

        #expect(YtDlpEvent(line: lines[0]) == .details(VideoDetails(
            id: "dQw4w9WgXcQ",
            title: "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)",
            channel: "Rick Astley",
            uploadDate: "20091025"
        )))
        #expect(YtDlpEvent(line: lines[1]) == .details(VideoDetails(
            id: "jNQXAC9IVRw", title: "Me at the zoo", channel: "jawed", uploadDate: "20050424"
        )))
    }

    @Test func missingValuesAreNil() {
        #expect(YtDlpEvent(line: "YT4S-DETAILS\tjNQXAC9IVRw\t\"Me at the zoo\"\tNA\tNA") == .details(VideoDetails(
            id: "jNQXAC9IVRw", title: "Me at the zoo", channel: nil, uploadDate: nil
        )))
    }

    @Test func theTemplatePrintsBeforeTheDownloadStarts() {
        #expect(YtDlpOutputTemplates.details.hasPrefix("before_dl:YT4S-DETAILS\t"))
    }
}
