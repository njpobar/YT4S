import Foundation
import Testing
@testable import YT4SCore

/// Which parts of the file a Snipped copy keeps once its Cut is left out.
@Suite struct SnipPlanTests {
    private func kept(_ cut: Cut, duration: Double = 60) -> [KeptSpan] {
        SnipPlan(duration: duration, cuts: [cut]).keptSpans
    }

    @Test func aCutInTheMiddleKeepsWhatIsBeforeAndAfterIt() {
        #expect(kept(Cut(start: 10, end: 25)) == [KeptSpan(start: 0, end: 10), KeptSpan(start: 25, end: 60)])
    }

    @Test func aCutAtTheStartKeepsTheRest() {
        #expect(kept(Cut(start: 0, end: 5)) == [KeptSpan(start: 5, end: 60)])
    }

    @Test func aCutAtTheEndKeepsTheBeginning() {
        #expect(kept(Cut(start: 50, end: 60)) == [KeptSpan(start: 0, end: 50)])
    }

    @Test func aCutPastTheEndStopsAtTheEnd() {
        #expect(kept(Cut(start: 50, end: 70)) == [KeptSpan(start: 0, end: 50)])
        #expect(kept(Cut(start: -3, end: 5)) == [KeptSpan(start: 5, end: 60)])
    }

    @Test func aCutOverTheWholeFileKeepsNothing() {
        let plan = SnipPlan(duration: 60, cuts: [Cut(start: 0, end: 60)])

        #expect(plan.keptSpans.isEmpty)
        #expect(plan.keptDuration == 0)
    }

    @Test func keptDurationIsTheFileLessTheCut() {
        #expect(SnipPlan(duration: 60, cuts: [Cut(start: 10, end: 25)]).keptDuration == 45)
    }

    @Test func aCutIsTheSameWhicheverEdgeWasDraggedFirst() {
        #expect(Cut(start: 25, end: 10) == Cut(start: 10, end: 25))
    }
}
