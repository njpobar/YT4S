import Foundation
import Observation

/// State behind the Snip window's timeline, in seconds of the original.
///
/// The user drags across the timeline to select a span (`select`), adjusts its two edge handles
/// (`moveSelectionStart` / `moveSelectionEnd`), and presses Cut (`cutSelection`). One Cut per
/// Snip: a new Cut replaces the old one. Save Snipped copy takes `plan`.
@MainActor @Observable
public final class SnipEditor {
    /// The original's length; 0 until the player has loaded it, and nothing can be selected.
    public var duration: Double = 0 {
        didSet { selection = selection.map(clamped) }
    }
    /// The span being marked, before it is Cut.
    public private(set) var selection: Cut?
    public private(set) var cut: Cut?

    public init() {}

    /// A drag across the timeline, from where it started to where it is now.
    public func select(from start: Double, to end: Double) {
        guard duration > 0 else { return }
        selection = clamped(Cut(start: start, end: end))
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

    public var canCut: Bool { (selection?.length ?? 0) > 0 }

    /// Cut: the selection becomes the Cut (replacing any earlier one) and is cleared.
    public func cutSelection() {
        guard canCut else { return }
        cut = selection
        selection = nil
    }

    /// What Save Snipped copy saves: `nil` (Save disabled) until there is a Cut that leaves
    /// something to keep.
    public var plan: SnipPlan? {
        guard let cut else { return nil }
        let plan = SnipPlan(duration: duration, cuts: [cut])
        return plan.keptDuration > 0 ? plan : nil
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

    /// `1:05.3`: minutes, seconds and tenths, for span edges and lengths.
    public nonisolated static func timeText(_ seconds: Double) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    private func clamped(_ span: Cut) -> Cut {
        Cut(start: min(max(span.start, 0), duration), end: min(max(span.end, 0), duration))
    }
}
