import Foundation

/// yt-dlp could not list a Playlist or Channel source (missing, private, network, ...).
public struct SourceExpansionError: Error, Equatable, Sendable {
    public var source: Source
    /// How yt-dlp ended; `nil` when it could not be launched at all.
    public var termination: SubprocessTermination?
    /// Raw yt-dlp stderr (or the launch error). Never shown to Sarah as is.
    public var details: String

    public init(source: Source, termination: SubprocessTermination?, details: String) {
        self.source = source
        self.termination = termination
        self.details = details
    }
}

/// Turns a Source into the videos it means, one `SourceEntry` per future Queue row.
///
/// Playlist and Channel sources are listed by yt-dlp with `--flat-playlist`, which reads only
/// the list pages (no per-video lookups), so even a large channel takes seconds.
public struct SourceExpander: Sendable {
    public var runner: YtDlpRunner

    public init(runner: YtDlpRunner) {
        self.runner = runner
    }

    static func arguments(for source: Source) -> [String] {
        ["--flat-playlist", "--yes-playlist", "--print", YtDlpOutputTemplates.entry, "--", source.url]
    }

    /// The videos of `source`, in playlist order. A video Source is itself (yt-dlp is not run).
    /// Throws `SourceExpansionError`, or `CancellationError` when the calling task is cancelled.
    public func expand(_ source: Source) async throws -> [SourceEntry] {
        if case .video(let id) = source {
            return [SourceEntry(
                videoID: id, url: source.url, title: nil,
                playlistIndex: nil, playlistCount: nil, playlistTitle: nil, playlistChannel: nil, channel: nil
            )]
        }
        var entries: [SourceEntry] = []
        do {
            for try await update in runner.run(Self.arguments(for: source)) {
                switch update {
                case .event(.entry(let entry)):
                    entries.append(entry)
                case .event:
                    break
                case .exited(let exit):
                    guard exit.succeeded else {
                        throw SourceExpansionError(source: source, termination: exit.termination, details: exit.stderr)
                    }
                }
            }
        } catch let error as SourceExpansionError {
            throw error
        } catch {
            throw SourceExpansionError(source: source, termination: nil, details: String(describing: error))
        }
        try Task.checkCancellation()
        return entries
    }
}
