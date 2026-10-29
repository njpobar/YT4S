import Foundation
import Testing
@testable import YT4SCore

/// One video's overall progress, folded from real captured yt-dlp output.
@Suite struct DownloadProgressTests {
    private func replay(_ fixture: String) throws -> [Double] {
        var progress = DownloadProgress()
        var fractions: [Double] = []
        for line in try Fixture.lines(fixture) {
            guard let event = YtDlpEvent(line: line) else { continue }
            progress.apply(event)
            if case .progress = event { fractions.append(try #require(progress.fraction)) }
        }
        return fractions
    }

    @Test func isIndeterminateBeforeAnyProgress() {
        #expect(DownloadProgress().fraction == nil)
    }

    @Test func mergedDownloadWeighsEachPartBySize() throws {
        let fractions = try replay("merged-video-audio")

        // The video part (223779 of 475961 bytes) finishing is 47% of the whole video.
        #expect(abs(fractions[8] - 223779.0 / 475961.0) < 0.0001)
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted(), "progress never goes backwards")
    }

    @Test func singleFormatDownloadRunsFromStartToOne() throws {
        let fractions = try replay("progressive")

        #expect(abs(fractions[0] - 1024.0 / 629172.0) < 0.0001)
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
    }

    @Test func fragmentedDownloadWithOnlyEstimatesDoesNotJumpToFull() throws {
        let fractions = try replay("hls-fragments")

        // The first tick has downloaded == estimate (712 of "712"), which must not read as 100%.
        #expect(fractions[0] == 0)
        #expect(fractions.dropLast().allSatisfy { $0 < 1 })
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
    }

    @Test func reportsSpeedAndTimeLeftOfTheCurrentPart() throws {
        var progress = DownloadProgress()
        for line in try Fixture.lines("merged-video-audio").prefix(4) {
            progress.apply(try #require(YtDlpEvent(line: line)))
        }

        #expect(progress.speed == 1359166.8658227848)
        #expect(progress.eta == 0)
    }
}
