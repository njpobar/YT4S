import Foundation
import Testing
@testable import YT4SCore

/// The Snip window's timeline: drag across it to select a span, adjust the span's two edge
/// handles, press Cut, then Save Snipped copy. One Cut per Snip for now.
@MainActor @Suite struct SnipEditorTests {
    private func editor(duration: Double = 60) -> SnipEditor {
        let editor = SnipEditor()
        editor.duration = duration
        return editor
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

    @Test func cutTurnsTheSelectionIntoTheCut() {
        let editor = editor()
        #expect(!editor.canCut)
        editor.select(from: 10, to: 20)
        #expect(editor.canCut)

        editor.cutSelection()

        #expect(editor.cut == Cut(start: 10, end: 20))
        #expect(editor.selection == nil)
        #expect(!editor.canCut)
    }

    @Test func anEmptySelectionCannotBeCut() {
        let editor = editor()
        editor.select(from: 10, to: 10)

        #expect(!editor.canCut)
        editor.cutSelection()
        #expect(editor.cut == nil)
    }

    @Test func aNewCutReplacesTheOldOne() {
        let editor = editor()
        editor.select(from: 10, to: 20)
        editor.cutSelection()
        editor.select(from: 40, to: 50)
        editor.cutSelection()

        #expect(editor.cut == Cut(start: 40, end: 50))
    }

    @Test func saveNeedsACutThatLeavesSomethingToKeep() {
        let editor = editor()
        #expect(editor.plan == nil)

        editor.select(from: 0, to: 60)
        editor.cutSelection()
        #expect(editor.plan == nil)

        editor.select(from: 10, to: 20)
        editor.cutSelection()
        #expect(editor.plan == SnipPlan(duration: 60, cuts: [Cut(start: 10, end: 20)]))
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
