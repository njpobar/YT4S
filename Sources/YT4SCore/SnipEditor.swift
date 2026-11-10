import Foundation
import Observation

/// State behind the Snip window's timeline, in seconds of the original.
///
/// The user drags across the timeline to select a span (`select`), adjusts its two edge handles
/// (`moveSelectionStart` / `moveSelectionEnd`), and presses Cut (`cutSelection`). Any number of
/// Cuts; overlapping or touching ones merge. Save Snipped copy takes `plan`.
@MainActor @Observable
public final class SnipEditor {
    /// The original's length; 0 until the player has loaded it, and nothing can be selected.
    public var duration: Double = 0 {
        didSet { selection = selection.map(clamped) }
    }
    /// The span being marked, before it is Cut.
    public private(set) var selection: Cut?
    /// In order, never overlapping or touching.
    public private(set) var cuts: [Cut] = []
    /// The Cut last clicked on the timeline, which shows a small x to remove it.
    public private(set) var pickedCut: Cut?

    public init() {}

    /// A drag across the timeline, from where it started to where it is now.
    public func select(from start: Double, to end: Double) {
        guard duration > 0 else { return }
        selection = clamped(Cut(start: start, end: end))
        pickedCut = nil
    }

    /// The selection's start handle; it stops at the end handle.
    public func moveSelectionStart(to time: Double) {
        guard let selection else { return }
        self.selection = Cut(start: min(max(time, 0), selection.end), end: selection.end)
    }

    /// The selection's end handle; it stops at the start handle.
    public func moveSelectionEnd(to time: Double) {
        guard let selection else { return }
        self.selection = Cut(start: selection.start, end: max(min(time, duration), selection.start))
    }

    /// The set-start shortcut at the playhead: the selection now starts at `time`. Without a
    /// selection, or when `time` is past its end, the span runs on to the end of the file.
    public func setSelectionStart(at time: Double) {
        let end = selection.map(\.end).flatMap { $0 >= time ? $0 : nil } ?? duration
        select(from: time, to: end)
    }

    /// The set-end shortcut at the playhead: the selection now ends at `time`. Without a
    /// selection, or when `time` is before its start, the span runs from the start of the file.
    public func setSelectionEnd(at time: Double) {
        let start = selection.map(\.start).flatMap { $0 <= time ? $0 : nil } ?? 0
        select(from: start, to: time)
    }

    public var canCut: Bool { (selection?.length ?? 0) > 0 }

    /// Cut: the selection becomes a Cut (merged with any it overlaps or touches) and is cleared.
    public func cutSelection() {
        guard canCut, let selection else { return }
        cuts = Cut.merged(cuts + [selection])
        self.selection = nil
        pickedCut = nil
    }

    /// A click on the timeline at `time`: picks the Cut there, or none.
    public func pickCut(at time: Double) {
        pickedCut = cuts.first { $0.start <= time && time <= $0.end }
    }

    /// The picked Cut's x: the Cut is gone, and its span is kept again.
    public func removePickedCut() {
        guard let pickedCut else { return }
        cuts.removeAll { $0 == pickedCut }
        self.pickedCut = nil
    }

    /// What Save Snipped copy saves: `nil` (Save disabled) while there are no Cuts, or they
    /// leave nothing to keep.
    public var plan: SnipPlan? {
        guard !cuts.isEmpty else { return nil }
        let plan = SnipPlan(duration: duration, cuts: cuts)
        return plan.keptDuration > 0 ? plan : nil
    }

    /// What playback reaching `time` does so it previews the Snipped copy: skip over the Cut it
    /// is in, or, in a Cut running to the end of the file, stop just before it (so play can
    /// start again). `nil` outside every Cut.
    public func playbackJump(at time: Double) -> PlaybackJump? {
        guard let cut = cuts.first(where: { $0.start <= time && time < $0.end }) else { return nil }
        return cut.end >= duration ? .stop(at: max(cut.start - Self.stopMargin, 0)) : .skip(to: cut.end)
    }

    /// Where play pressed at `time` starts: at the end of the preview (nothing kept is left to
    /// play), the first moment kept; otherwise `nil`, right where it is.
    public func playbackRestart(at time: Double) -> Double? {
        let kept = SnipPlan(duration: duration, cuts: cuts).keptSpans
        guard let first = kept.first, kept.allSatisfy({ $0.end <= time + Self.endSlack }) else { return nil }
        return first.start
    }

    /// What playback does at a Cut.
    public enum PlaybackJump: Equatable, Sendable {
        /// Plays on from the Cut's end.
        case skip(to: Double)
        /// Pauses here, the last moment kept.
        case stop(at: Double)
    }

    /// How far before an end Cut playback stops, so the playhead is outside it.
    private static let stopMargin = 0.001
    /// How near the last kept moment counts as the end of the preview.
    private static let endSlack = 0.05

    /// The playhead `by` seconds on from `time` (back when negative), within the file.
    public func step(from time: Double, by seconds: Double) -> Double {
        min(max(time + seconds, 0), duration)
    }

    /// One of the selection's two edge handles.
    public enum Handle: Equatable, Sendable {
        case start, end
    }

    /// The handle a drag starting at `time` grabs: the nearer one within `reach` seconds, or `nil`
    /// (the drag selects a new span instead).
    public func handle(near time: Double, reach: Double) -> Handle? {
        guard let selection else { return nil }
        let toStart = abs(time - selection.start)
        let toEnd = abs(time - selection.end)
        guard min(toStart, toEnd) <= reach else { return nil }
        return toEnd < toStart ? .end : .start
    }

    /// The line under the timeline: the selection being marked, the picked Cut, the Cuts, or
    /// how to start.
    public var status: String {
        if let selection {
            return "Selected \(Self.timeText(selection.start)) - \(Self.timeText(selection.end)). Press Cut to leave it out."
        }
        if let pickedCut {
            return "Cut \(Self.timeText(pickedCut.start)) - \(Self.timeText(pickedCut.end)) (\(Self.timeText(pickedCut.length))). Click x to keep it."
        }
        guard !cuts.isEmpty else { return "Drag across the timeline to select the part to cut." }
        let count = cuts.count == 1 ? "1 Cut" : "\(cuts.count) Cuts"
        guard let plan else { return "\(count) over the whole file. Remove one to keep something." }
        return "\(count). The Snipped copy runs \(Self.timeText(plan.keptDuration))."
    }

    /// `1:05.3`: minutes, seconds and tenths, for span edges and lengths.
    public nonisolated static func timeText(_ seconds: Double) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    private func clamped(_ span: Cut) -> Cut {
        Cut(start: min(max(span.start, 0), duration), end: min(max(span.end, 0), duration))
    }
}
