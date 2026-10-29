import Foundation
import Testing
@testable import YT4SCore

/// The Looks-outdated banner and early stop (#11, #31), on the real Queue against the fake
/// yt-dlp's `outdated` scenario.
@MainActor @Suite struct OutdatedBannerTests {
    private func request(_ fake: FakeYtDlp, id: String) -> DownloadRequest {
        DownloadRequest(url: "https://www.youtube.com/watch?v=\(id)", downloadFolder: fake.downloadFolder, options: .default)
    }

    /// A Queue whose videos fail as Looks outdated when their ID is in `failing` (every video when nil).
    private func queue(_ fake: FakeYtDlp, failing: [String]? = nil) -> Queue {
        let extra = failing.map { ["YT4S_FAKE_FAIL_IDS": $0.joined(separator: ",")] } ?? [:]
        return Queue(runner: fake.runner(scenario: "outdated", extraEnvironment: extra))
    }

    private func run(_ queue: Queue, _ fake: FakeYtDlp, _ ids: [String]) async {
        for id in ids { queue.add(request(fake, id: id)) }
        await queue.waitUntilIdle()
    }

    @Test func twoLooksOutdatedFailuresInABatchShowTheBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake, failing: ["a", "c"])

        await run(queue, fake, ["a", "b", "c"])

        #expect(queue.items.map(\.isFailed) == [true, false, true])
        #expect(queue.showsOutdatedBanner)
    }

    @Test func oneLooksOutdatedFailureAmongSeveralVideosShowsNoBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake, failing: ["b"])

        await run(queue, fake, ["a", "b", "c"])

        #expect(!queue.showsOutdatedBanner)
    }

    @Test func aSingleVideoBatchThatLooksOutdatedShowsTheBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake)

        await run(queue, fake, ["a"])

        #expect(queue.showsOutdatedBanner)
    }

    @Test func otherFailuresNeverShowTheBanner() async throws {
        let fake = try FakeYtDlp()
        let queue = Queue(runner: fake.runner(scenario: "video-failure"))

        await run(queue, fake, ["a", "b"])

        #expect(queue.items.map(\.isFailed) == [true, true])
        #expect(!queue.showsOutdatedBanner)
    }

    @Test func failuresInAnEarlierBatchDoNotCountTowardsTheNextOne() async throws {
        let fake = try FakeYtDlp()
        let queue = queue(fake, failing: ["a", "c"])

        await run(queue, fake, ["a", "b"])
        await run(queue, fake, ["c", "d"])

        #expect(!queue.showsOutdatedBanner)
    }

    @Test func theBannerSaysWhatToDo() {
        #expect(OutdatedBanner.text(updateAppliedThisSession: false) == "YouTube may have changed. Try Update yt-dlp below.")
    }
}
