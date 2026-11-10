import Foundation

/// Why a Snip did not save its Snipped copy.
public struct SnipFailure: Error, Equatable, Sendable {
    /// Raw ffmpeg stderr, or the error that stopped the save.
    public var details: String
}

/// Makes a Snipped copy with the bundled ffmpeg (`SnipArguments`).
///
/// ffmpeg writes into a subfolder of the Download folder's hidden incomplete folder (same volume,
/// so placing is a rename; a quit mid-Snip removes it, `Queue.stopSnipsForQuit`). Once it
/// succeeds the copy is moved next to the original under its Snipped copy name and tagged like
/// the original, so it counts as Already downloaded, and marked as a Snipped copy, so the
/// original wins when both exist. The original is only ever read.
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

    /// A new folder for one Snip to write into, inside `folder`'s hidden incomplete folder.
    public static func newWorkFolder(in folder: DownloadFolder) -> URL {
        folder.incompleteFolder.appendingPathComponent("snip-\(UUID().uuidString)", isDirectory: true)
    }

    /// Snips `source`, a file of `folder` saved as `video` (its original, or its Snipped copy when
    /// the original is gone), with ffmpeg writing into `workFolder` (`newWorkFolder`). Returns the
    /// Snipped copy, placed and tagged, after reporting how much of it ffmpeg has written (0 to 1)
    /// to `onProgress`, in order. Throws a `SnipFailure`, or `CancellationError` when the calling
    /// task is cancelled (ffmpeg is stopped); either way it returns only once `workFolder` and any
    /// copy it placed are gone.
    public func snip(
        _ source: SnipSource, video: SavedVideo, plan: SnipPlan, in folder: DownloadFolder, workFolder: URL,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let input = source.file
        let partial = workFolder.appendingPathComponent("snipped").appendingPathExtension(input.pathExtension)
        // Its own subfolder, removed when done; the incomplete folder itself is left alone, as a
        // download may be about to write into it.
        defer { try? FileManager.default.removeItem(at: workFolder) }
        do {
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
            let keptDuration = plan.keptDuration
            let bitrates = await Self.bitrates(of: input, ffprobe: ffprobe, environment: environment)
            let result = try await Subprocess.run(
                executable: ffmpeg,
                arguments: SnipArguments.arguments(input: input, output: partial, format: video.format, plan: plan, bitrates: bitrates),
                environment: environment,
                onStdoutLine: { line in
                    if let fraction = SnipArguments.fraction(ofProgressLine: line, keptDuration: keptDuration) {
                        onProgress(fraction)
                    }
                }
            )
            try Task.checkCancellation()
            guard result.termination == .exited(0) else { throw SnipFailure(details: result.stderr) }
            let copy = SnippedCopy.file(for: input, sourceIsSnippedCopy: source.isSnippedCopy) { FileManager.default.fileExists(atPath: $0.path) }
            // Fails rather than replaces if a file appeared there meanwhile.
            try FileManager.default.moveItem(at: partial, to: copy)
            do {
                try folder.tag(copy, with: video, asSnippedCopy: true)
                // Cancelled while placing it: the copy is not kept either.
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            return copy
        } catch let error as SnipFailure {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SnipFailure(details: String(describing: error))
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
