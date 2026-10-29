import Testing
@testable import YT4SCore

@Suite struct YtDlpVersionTests {
    @Test func nightlyTagsOrderByDateThenBuildTime() throws {
        let older = try #require(YtDlpVersion("2026.10.26.220202"))
        let newer = try #require(YtDlpVersion("2026.10.27.010101"))
        #expect(older < newer)
        #expect(!(newer < older))
    }

    @Test func componentsCompareNumericallyNotAsText() throws {
        #expect(try #require(YtDlpVersion("2026.9.30")) < #require(YtDlpVersion("2026.10.1")))
    }

    @Test func aStableTagIsOlderThanANightlyFromTheSameDay() throws {
        #expect(try #require(YtDlpVersion("2026.10.21")) < #require(YtDlpVersion("2026.10.21.000101")))
    }

    @Test func keepsTheTagItWasMadeFrom() {
        #expect(YtDlpVersion("2026.10.26.220202")?.tag == "2026.10.26.220202")
    }

    @Test func rejectsAnythingThatIsNotADottedNumber() {
        #expect(YtDlpVersion("") == nil)
        #expect(YtDlpVersion("latest") == nil)
        #expect(YtDlpVersion("2026.10..1") == nil)
        #expect(YtDlpVersion("../2026.10.26") == nil)
        #expect(YtDlpVersion("v2026.10.26") == nil)
    }
}
