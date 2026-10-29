import Foundation

/// One video's overall download progress, folded from `YtDlpEvent`s.
///
/// yt-dlp downloads a merged video as separate parts (video, then audio), each reporting its own
/// 0 to 100%. This combines them into one fraction for the Queue row, weighting each part by its
/// size when known and equally otherwise, and never lets the bar move backwards.
public struct DownloadProgress: Equatable, Sendable {
    /// 0...1, or `nil` while nothing has been downloaded yet (indeterminate).
    public private(set) var fraction: Double?
    /// Bytes per second of the part being downloaded.
    public private(set) var speed: Double?
    /// Seconds left for the part being downloaded.
    public private(set) var eta: Int?

    private var formatIDs: [String] = []
    private var partSizes: [Int64?] = []

    public init() {}

    public mutating func apply(_ event: YtDlpEvent) {
        switch event {
        case .video(let info):
            formatIDs = info.formatIDs
            partSizes = info.partSizes
        case .progress(let part):
            speed = part.speed
            eta = part.eta
            let overall = overallFraction(part)
            fraction = max(fraction ?? 0, overall)
        case .file:
            fraction = 1
            speed = nil
            eta = 0
        }
    }

    private func overallFraction(_ part: PartProgress) -> Double {
        let partFraction = Self.fraction(of: part)
        guard formatIDs.count > 1, let index = formatIDs.firstIndex(of: part.formatID) else {
            return partFraction
        }
        let weights: [Double]
        if partSizes.count == formatIDs.count, partSizes.allSatisfy({ ($0 ?? 0) > 0 }) {
            let sizes = partSizes.map { Double($0 ?? 0) }
            let total = sizes.reduce(0, +)
            weights = sizes.map { $0 / total }
        } else {
            weights = Array(repeating: 1 / Double(formatIDs.count), count: formatIDs.count)
        }
        let done = weights[..<index].reduce(0, +)
        return min(1, done + weights[index] * partFraction)
    }

    /// Progress of a single part: exact bytes when the total is known, else fragments, else the
    /// byte estimate (which early on can equal the downloaded bytes, so it is trusted last).
    private static func fraction(of part: PartProgress) -> Double {
        if part.status == .finished { return 1 }
        if let total = part.totalBytes, total > 0, let done = part.downloadedBytes {
            return clamp(Double(done) / Double(total))
        }
        if let count = part.fragmentCount, count > 0, let index = part.fragmentIndex {
            return clamp(Double(index) / Double(count))
        }
        if let estimate = part.totalBytesEstimate, estimate > 0, let done = part.downloadedBytes {
            return clamp(Double(done) / Double(estimate))
        }
        return 0
    }

    /// A part still downloading is never shown as complete: yt-dlp's fragment index can run past
    /// its fragment count, and estimates can undershoot. Only `finished` reaches 1.
    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 0.99)
    }
}
