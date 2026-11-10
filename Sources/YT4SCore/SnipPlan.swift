import Foundation

/// One span of a video marked to be left out of the Snipped copy (`GLOSSARY.md`), in seconds
/// from the start. Always `start <= end`, whichever edge was set first.
public struct Cut: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var length: Double { end - start }
}

/// A span of the original the Snipped copy keeps, in seconds.
public struct KeptSpan: Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var length: Double { end - start }
}

/// What one Snip makes of a file: its Cuts against its duration, and what is left.
public struct SnipPlan: Equatable, Sendable {
    /// The original's length in seconds.
    public var duration: Double
    public var cuts: [Cut]

    public init(duration: Double, cuts: [Cut]) {
        self.duration = duration
        self.cuts = cuts
    }

    /// The spans between the Cuts, in order, each Cut clamped to the file. Empty when the Cuts
    /// cover it all.
    public var keptSpans: [KeptSpan] {
        var spans: [KeptSpan] = []
        var position = 0.0
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            let start = min(max(cut.start, 0), duration)
            if start > position { spans.append(KeptSpan(start: position, end: start)) }
            position = max(position, min(cut.end, duration))
        }
        if position < duration { spans.append(KeptSpan(start: position, end: duration)) }
        return spans
    }

    /// How long the Snipped copy runs.
    public var keptDuration: Double { keptSpans.reduce(0) { $0 + $1.length } }
}
