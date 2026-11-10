import Foundation

/// Why a Snip did not save its Snipped copy.
public struct SnipFailure: Error, Equatable, Sendable {
    /// Raw ffmpeg stderr, or the error that stopped the save.
    public var details: String
}

/// What a running Snip reports, in order.
public enum SnipUpdate: Equatable, Sendable {
    /// How much of the Snipped copy ffmpeg has written, 0 to 1.
    case progress(Double)
    /// Always the last update of a Snip that succeeded: the Snipped copy, placed and tagged.
    case saved(URL)
}

/// Makes a Snipped copy with the bundled ffmpeg (`SnipArguments`).
///
/// ffmpeg writes into a subfolder of the Download folder's hidden incomplete folder (same volume,
/// so placing is a rename, and a quit mid-Snip leaves nothing the next launch does not remove). Once it
/// succeeds the copy is moved next to the original under its Snipped copy name and tagged like
/// the original, so it counts as Already downloaded. The original is only ever read.
public struct Snipper: Sendable {
    public var ffmpeg: URL
    /// Reads the original's bitrates, so the copy keeps them.
    public var ffprobe: URL
    /// `nil` inherits the app's environment.
    public var environment: [String: String]?

    public init(tools: BundledTools, environment: [String: String]? = nil) {
        ffmpeg = tools.ffmpegDirectory.appendingPathComponent("ffmpeg")
        ffprobe = tools.ffmpegDirectory.appendingPathComponent("ffprobe")
        self.environment = environment
    }

    /// Snips `original`, a file of `folder` saved as `video`. Ends with `.saved`, or throws a
    /// `SnipFailure` with nothing left behind. Cancelling the consumer stops ffmpeg.
    public func snip(_ original: URL, video: SavedVideo, plan: SnipPlan, in folder: DownloadFolder) -> AsyncThrowingStream<SnipUpdate, Error> {
        let ffmpeg = ffmpeg
        let ffprobe = ffprobe
        let environment = environment
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Its own subfolder, removed when done; the incomplete folder itself is left
                // alone, as a download may be about to write into it.
                let workFolder = folder.incompleteFolder.appendingPathComponent("snip-\(UUID().uuidString)", isDirectory: true)
                let partial = workFolder.appendingPathComponent("snipped").appendingPathExtension(original.pathExtension)
                defer { try? FileManager.default.removeItem(at: workFolder) }
                do {
                    try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
                    let keptDuration = plan.keptDuration
                    let bitrates = await Self.bitrates(of: original, ffprobe: ffprobe, environment: environment)
                    let result = try await Subprocess.run(
                        executable: ffmpeg,
                        arguments: SnipArguments.arguments(input: original, output: partial, format: video.format, plan: plan, bitrates: bitrates),
                        environment: environment,
                        onStdoutLine: { line in
                            if let fraction = SnipArguments.fraction(ofProgressLine: line, keptDuration: keptDuration) {
                                continuation.yield(.progress(fraction))
                            }
                        }
                    )
                    try Task.checkCancellation()
                    guard result.termination == .exited(0) else { throw SnipFailure(details: result.stderr) }
                    let copy = SnippedCopy.file(for: original) { FileManager.default.fileExists(atPath: $0.path) }
                    // Fails rather than replaces if a file appeared there meanwhile.
                    try FileManager.default.moveItem(at: partial, to: copy)
                    do {
                        try folder.tag(copy, with: video)
                    } catch {
                        try? FileManager.default.removeItem(at: copy)
                        throw error
                    }
                    continuation.yield(.saved(copy))
                    continuation.finish()
                } catch let failure as SnipFailure {
                    continuation.finish(throwing: failure)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: SnipFailure(details: String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The original's bitrates, or unknown ones if ffprobe cannot tell (the copy then gets a
    /// high quality instead).
    private static func bitrates(of original: URL, ffprobe: URL, environment: [String: String]?) async -> SourceBitrates {
        guard let result = try? await Subprocess.run(
            executable: ffprobe,
            arguments: ["-v", "error", "-of", "json", "-show_streams", original.path],
            environment: environment
        ), result.termination == .exited(0) else { return SourceBitrates() }
        return SourceBitrates(ffprobeJSON: Data(result.stdout.utf8))
    }
}
