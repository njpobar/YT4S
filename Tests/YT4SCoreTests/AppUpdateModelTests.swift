import Foundation
import Testing
@testable import YT4SCore

@MainActor @Suite struct AppUpdateModelTests {
    @Test func checksOnStartAndShowsADotWhenAnUpdateIsFound() {
        let engine = FakeAppUpdateEngine()
        let model = AppUpdateModel(engine: engine, currentVersion: "1.0.0")
        #expect(model.showsDot == false)

        model.start()
        #expect(engine.backgroundChecks == 1)
        #expect(model.showsDot == false)

        engine.report(.found(version: "1.1.0"))
        #expect(model.showsDot)
        #expect(engine.installs == 0, "a found update only shows a dot")
    }

    @Test func checksAgainOnceADayWhileLeftOpen() async {
        let engine = FakeAppUpdateEngine()
        let days = ManualTimer()
        let model = AppUpdateModel(engine: engine, currentVersion: "1.0.0", sleep: days.sleep)

        model.start()
        await days.waitForSleeper()
        #expect(days.requested == [.seconds(24 * 60 * 60)])
        #expect(engine.backgroundChecks == 1)

        days.fire()
        await days.waitForSleeper()
        #expect(engine.backgroundChecks == 2)

        model.stop()
        days.fire()
        await Task.yield()
        #expect(engine.backgroundChecks == 2)
    }

    @Test func clickingInstallsAndDisablesTheButtonUntilSparkleRelaunches() {
        let engine = FakeAppUpdateEngine()
        let model = AppUpdateModel(engine: engine, currentVersion: "1.0.0")
        model.start()
        engine.report(.found(version: "1.1.0"))
        #expect(model.isEnabled)
        #expect(model.title == "Update app")

        model.updateApp()

        #expect(engine.installs == 1)
        #expect(model.isEnabled == false)
        #expect(model.title == "Updating…")
        model.updateApp()
        #expect(engine.installs == 1, "a second click while updating does nothing")
    }

    @Test func isDisabledWithAHintWhileAnyDownloadRuns() {
        let engine = FakeAppUpdateEngine()
        let model = AppUpdateModel(engine: engine, currentVersion: "1.0.0")
        engine.report(.found(version: "1.1.0"))

        model.downloadsRunning = true

        #expect(model.isEnabled == false)
        #expect(model.hint == "Finish or cancel the Queue first.")
        #expect(model.hint == UpdateButtonHint.downloadsRunning)
        #expect(model.showsDot, "the dot still says an update is waiting")
        model.updateApp()
        #expect(engine.installs == 0)

        model.downloadsRunning = false
        #expect(model.isEnabled)
        #expect(model.hint == nil)
    }
}

@MainActor @Suite struct AppUpdateModelFailureTests {
    @Test(arguments: [
        (AppUpdateFailure.offline, """
            YT4S couldn't reach GitHub, so it stayed on version 1.0.0.
            Check your internet connection, then click Update app again.
            """),
        (AppUpdateFailure.badSignature, """
            The downloaded update failed its security check, so it was not installed.
            YT4S stayed on version 1.0.0. Tell Nick.
            """),
        (AppUpdateFailure.other, """
            The update didn't install, so YT4S stayed on version 1.0.0.
            Try Update app again later. If it keeps failing, tell Nick.
            """),
    ])
    func aFailedUpdateKeepsTheCurrentVersionAndExplainsInTheFooter(failure: AppUpdateFailure, message: String) {
        let engine = FakeAppUpdateEngine()
        let model = AppUpdateModel(engine: engine, currentVersion: "1.0.0")
        engine.report(.found(version: "1.1.0"))
        model.updateApp()

        engine.report(.failed(failure))

        #expect(model.isUpdating == false)
        #expect(model.isEnabled, "the user can try again with another click")
        #expect(model.showsDot)
        #expect(model.message == message)
        #expect(message.split(separator: "\n").count <= 3)
    }

    @Test func aFailedBackgroundCheckStaysQuiet() {
        let engine = FakeAppUpdateEngine()
        let model = AppUpdateModel(engine: engine, currentVersion: "1.0.0")
        model.start()

        engine.report(.failed(.offline))

        #expect(model.message == nil)
        #expect(model.showsDot == false)
    }

    @Test func clickingWithNothingNewSaysSoAndClearsTheDot() {
        let engine = FakeAppUpdateEngine()
        let model = AppUpdateModel(engine: engine, currentVersion: "1.0.0")

        model.updateApp()
        engine.report(.upToDate)

        #expect(model.isUpdating == false)
        #expect(model.showsDot == false)
        #expect(model.message == "YT4S 1.0.0 is up to date.")
    }

    @Test func theNextClickClearsTheOldMessage() {
        let engine = FakeAppUpdateEngine()
        let model = AppUpdateModel(engine: engine, currentVersion: "1.0.0")
        model.updateApp()
        engine.report(.failed(.offline))

        model.updateApp()

        #expect(model.message == nil)
        #expect(engine.installs == 2)
    }

    @Test func aBackgroundCheckThatFindsNothingClearsTheDot() {
        let engine = FakeAppUpdateEngine()
        let model = AppUpdateModel(engine: engine, currentVersion: "1.0.0")
        engine.report(.found(version: "1.1.0"))

        engine.report(.upToDate)

        #expect(model.showsDot == false)
        #expect(model.message == nil, "only a click reports up to date")
    }
}

/// A sleep that only returns when the test fires it.
@MainActor final class ManualTimer {
    private(set) var requested: [Duration] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var sleeperWaiters: [CheckedContinuation<Void, Never>] = []

    var sleep: @MainActor @Sendable (Duration) async throws -> Void {
        { [weak self] duration in
            guard let self else { return }
            requested.append(duration)
            await withCheckedContinuation { continuation in
                pending = continuation
                sleeperWaiters.forEach { $0.resume() }
                sleeperWaiters = []
            }
            try Task.checkCancellation()
        }
    }

    /// Returns once something is asleep on this timer.
    func waitForSleeper() async {
        if pending != nil { return }
        await withCheckedContinuation { sleeperWaiters.append($0) }
    }

    func fire() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}

/// Stands in for Sparkle: records what the model asked for; the test reports what Sparkle would.
@MainActor final class FakeAppUpdateEngine: AppUpdateEngine {
    var onEvent: (@MainActor (AppUpdateEvent) -> Void)?
    private(set) var backgroundChecks = 0
    private(set) var installs = 0

    func checkInBackground() { backgroundChecks += 1 }
    func install() { installs += 1 }

    func report(_ event: AppUpdateEvent) { onEvent?(event) }
}
