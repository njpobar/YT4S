import Foundation
import Testing
@testable import YT4SCore

/// The Snip window's timeline: drag across it to select a span, adjust the span's two edge
/// handles, press Cut; any number of Cuts, then Save Snipped copy.
@MainActor @Suite struct SnipEditorTests {
    private func editor(duration: Double = 60) -> SnipEditor {
        let editor = SnipEditor()
        editor.duration = duration
        return editor
    }

    private func cut(_ editor: SnipEditor, _ start: Double, _ end: Double) {
        editor.select(from: start, to: end)
        editor.cutSelection()
    }

    @Test func dragAcrossTheTimelineSelectsASpanInEitherDirection() {
        let editor = editor()

        editor.select(from: 30, to: 12)

        #expect(editor.selection == Cut(start: 12, end: 30))
    }

    @Test func aSelectionStaysInsideTheFile() {
        let editor = editor()

        editor.select(from: -5, to: 80)

        #expect(editor.selection == Cut(start: 0, end: 60))
    }

    @Test func theEdgeHandlesMoveOneEdgeAndNeverCrossTheOther() {
        let editor = editor()
        editor.select(from: 10, to: 20)

        editor.moveSelectionStart(to: 5)
        #expect(editor.selection == Cut(start: 5, end: 20))
        editor.moveSelectionEnd(to: 42)
        #expect(editor.selection == Cut(start: 5, end: 42))
        editor.moveSelectionStart(to: 50)
        #expect(editor.selection == Cut(start: 42, end: 42))
        editor.moveSelectionEnd(to: 99)
        #expect(editor.selection == Cut(start: 42, end: 60))
    }

    @Test func cutTurnsTheSelectionIntoACut() {
        let editor = editor()
        #expect(!editor.canCut)
        editor.select(from: 10, to: 20)
        #expect(editor.canCut)

        editor.cutSelection()

        #expect(editor.cuts == [Cut(start: 10, end: 20)])
        #expect(editor.selection == nil)
        #expect(!editor.canCut)
    }

    @Test func anEmptySelectionCannotBeCut() {
        let editor = editor()
        editor.select(from: 10, to: 10)

        #expect(!editor.canCut)
        editor.cutSelection()
        #expect(editor.cuts.isEmpty)
    }

    @Test func severalCutsAreKeptInOrder() {
        let editor = editor()
        cut(editor, 40, 50)
        cut(editor, 0, 5)
        cut(editor, 55, 60)

        #expect(editor.cuts == [Cut(start: 0, end: 5), Cut(start: 40, end: 50), Cut(start: 55, end: 60)])
    }

    @Test func overlappingOrTouchingCutsMergeIntoOne() {
        let editor = editor()
        cut(editor, 10, 20)
        cut(editor, 15, 30)
        cut(editor, 30, 35)
        cut(editor, 40, 45)

        #expect(editor.cuts == [Cut(start: 10, end: 35), Cut(start: 40, end: 45)])
    }

    @Test func aCutOverSeveralOthersSwallowsThem() {
        let editor = editor()
        cut(editor, 10, 12)
        cut(editor, 20, 22)
        cut(editor, 5, 25)

        #expect(editor.cuts == [Cut(start: 5, end: 25)])
    }

    @Test func saveNeedsACutThatLeavesSomethingToKeep() {
        let editor = editor()
        #expect(editor.plan == nil)

        cut(editor, 10, 20)
        #expect(editor.plan == SnipPlan(duration: 60, cuts: [Cut(start: 10, end: 20)]))

        cut(editor, 0, 10)
        cut(editor, 20, 60)
        #expect(editor.plan == nil)
    }

    @Test func clickingACutPicksItAndItsXRemovesIt() {
        let editor = editor()
        cut(editor, 10, 20)
        cut(editor, 40, 50)

        editor.pickCut(at: 45)
        #expect(editor.pickedCut == Cut(start: 40, end: 50))
        editor.removePickedCut()

        #expect(editor.cuts == [Cut(start: 10, end: 20)])
        #expect(editor.pickedCut == nil)
    }

    @Test func clickingOutsideEveryCutPicksNone() {
        let editor = editor()
        cut(editor, 10, 20)
        editor.pickCut(at: 15)

        editor.pickCut(at: 30)

        #expect(editor.pickedCut == nil)
        editor.removePickedCut()
        #expect(editor.cuts == [Cut(start: 10, end: 20)])
    }

    @Test func aNewSelectionDropsThePick() {
        let editor = editor()
        cut(editor, 10, 20)
        editor.pickCut(at: 15)

        editor.select(from: 30, to: 40)

        #expect(editor.pickedCut == nil)
    }

    @Test func shortcutsSetTheSpansStartAndEndAtThePlayhead() {
        let editor = editor()

        editor.setSelectionStart(at: 12)
        editor.setSelectionEnd(at: 30)

        #expect(editor.selection == Cut(start: 12, end: 30))
    }

    @Test func aStartWithoutAnEndRunsToTheEndOfTheFile() {
        let editor = editor()

        editor.setSelectionStart(at: 50)

        #expect(editor.selection == Cut(start: 50, end: 60))
    }

    @Test func anEndWithoutAStartRunsFromTheStartOfTheFile() {
        let editor = editor()

        editor.setSelectionEnd(at: 8)

        #expect(editor.selection == Cut(start: 0, end: 8))
    }

    @Test func aStartPastTheEndStartsANewSpanToTheEndOfTheFile() {
        let editor = editor()
        editor.select(from: 10, to: 20)

        editor.setSelectionStart(at: 40)
        #expect(editor.selection == Cut(start: 40, end: 60))

        editor.setSelectionEnd(at: 30)
        #expect(editor.selection == Cut(start: 0, end: 30))
    }

    @Test func playbackReachingACutJumpsToItsEnd() {
        let editor = editor()
        cut(editor, 0, 5)
        cut(editor, 20, 30)

        #expect(editor.playbackSkip(at: 0) == 5)
        #expect(editor.playbackSkip(at: 20) == 30)
        #expect(editor.playbackSkip(at: 29.9) == 30)
        #expect(editor.playbackSkip(at: 30) == nil)
        #expect(editor.playbackSkip(at: 10) == nil)
    }

    @Test func playbackReachingACutAtTheEndJumpsToTheEndOfTheFile() {
        let editor = editor()
        cut(editor, 50, 60)

        #expect(editor.playbackSkip(at: 55) == 60)
    }

    @Test func arrowKeysStepThePlayheadWithinTheFile() {
        let editor = editor()

        #expect(editor.step(from: 10, by: 0.5) == 10.5)
        #expect(editor.step(from: 10, by: -1) == 9)
        #expect(editor.step(from: 0.2, by: -1) == 0)
        #expect(editor.step(from: 59.8, by: 1) == 60)
    }

    @Test func theStatusSaysHowToStart() {
        #expect(editor().status == "Drag across the timeline to select the part to cut.")
    }

    @Test func theStatusShowsTheSelectionFirst() {
        let editor = editor()
        cut(editor, 0, 5)
        editor.select(from: 10, to: 20)

        #expect(editor.status == "Selected 0:10.0 - 0:20.0. Press Cut to leave it out.")
    }

    @Test func theStatusShowsThePickedCut() {
        let editor = editor()
        cut(editor, 10, 25.5)
        editor.pickCut(at: 12)

        #expect(editor.status == "Cut 0:10.0 - 0:25.5 (0:15.5). Click x to keep it.")
    }

    @Test func theStatusCountsTheCutsAndSaysHowLongTheCopyRuns() {
        let editor = editor()
        cut(editor, 0, 5)
        #expect(editor.status == "1 Cut. The Snipped copy runs 0:55.0.")

        cut(editor, 50, 60)
        #expect(editor.status == "2 Cuts. The Snipped copy runs 0:45.0.")
    }

    @Test func theStatusSaysWhenTheCutsLeaveNothing() {
        let editor = editor()
        cut(editor, 0, 30)
        cut(editor, 30, 60)

        #expect(editor.status == "1 Cut over the whole file. Remove one to keep something.")
    }

    @Test func nothingCanBeSelectedBeforeTheDurationIsKnown() {
        let editor = SnipEditor()

        editor.select(from: 1, to: 2)

        #expect(editor.selection == nil)
    }

    @Test func aDragStartingNearAnEdgeHandleMovesThatEdge() {
        let editor = editor()
        editor.select(from: 10, to: 20)

        #expect(editor.handle(near: 10.3, reach: 0.5) == .start)
        #expect(editor.handle(near: 19.6, reach: 0.5) == .end)
        #expect(editor.handle(near: 15, reach: 0.5) == nil)
    }

    @Test func aTinySelectionGivesTheNearerHandle() {
        let editor = editor()
        editor.select(from: 10, to: 10.2)

        #expect(editor.handle(near: 10.05, reach: 0.5) == .start)
        #expect(editor.handle(near: 10.15, reach: 0.5) == .end)
    }

    @Test func withoutASelectionThereAreNoHandles() {
        #expect(editor().handle(near: 0, reach: 1) == nil)
    }

    @Test(arguments: [
        (0.0, "0:00.0"),
        (4.44, "0:04.4"),
        (65.3, "1:05.3"),
        (599.96, "10:00.0"),
    ])
    func timesReadAsMinutesSecondsAndTenths(seconds: Double, text: String) {
        #expect(SnipEditor.timeText(seconds) == text)
    }
}
