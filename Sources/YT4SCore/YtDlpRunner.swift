import Foundation
import os

/// How a yt-dlp run ended.
public struct YtDlpExit: Equatable, Sendable {
    public var termination: SubprocessTermination
    /// Raw stderr: input for failure categorization and the row's Details disclosure.
    /// Never shown in a Queue row as is.
    public var stderr: String

    public init(termination: SubprocessTermination, stderr: String) {
        self.termination = termination
        self.stderr = stderr
    }

    public var succeeded: Bool { termination == .exited(0) }
}

public enum YtDlpRunUpdate: Equatable, Sendable {
    /// One of YT4S's own machine-readable stdout lines, as soon as yt-dlp prints it.
    case event(YtDlpEvent)
    /// Always the last update of a run that launched.
    case exited(YtDlpExit)
}

/// Runs yt-dlp and streams what it reports.
///
/// The one place that launches yt-dlp: every run gets the mandatory flags from `YtDlpCommand`,
/// and only `YtDlpEvent` lines on stdout are surfaced (normal human output is discarded).
/// The executable is `selection`'s copy (the updater's choice: newer of downloaded and bundled),
/// read at the start of each run, else `tools.ytDlp`. Tests point either at the fake yt-dlp.
public struct YtDlpRunner: Sendable {
    public var tools: BundledTools
    /// `nil` inherits the app's environment.
    public var environment: [String: String]?
    /// Which yt-dlp copy to run, as chosen by the updater. `nil` runs `tools.ytDlp`.
    public var selection: YtDlpSelection?

    public init(tools: BundledTools, environment: [String: String]? = nil, selection: YtDlpSelection? = nil) {
        self.tools = tools
        self.environment = environment
        self.selection = selection
    }

    /// Starts yt-dlp with `arguments` after the mandatory flags. Ends with `.exited`, or throws
    /// if the executable could not be launched. Cancelling the consumer terminates yt-dlp.
    ///
    /// When the selected copy does not start at all (see `looksLikeLaunchFailure`), the
    /// selection falls back to the next copy that does (active, previous, bundled; ADR 0002) and
    /// the run is retried on it, so a copy that breaks mid-session costs no video.
    public func run(_ arguments: [String]) -> AsyncThrowingStream<YtDlpRunUpdate, Error> {
        let argv = YtDlpCommand(tools: tools).arguments(arguments)
        let environment = environment
        let selection = selection
        let fallbackExecutable = tools.ytDlp
        return AsyncThrowingStream { continuation in
            let task = Task {
                var copy = selection?.copy
                // At most one retry per copy of the chain (active, previous, bundled).
                for attempt in 0... {
                    let sawEvent = OSAllocatedUnfairLock(initialState: false)
                    let outcome: Result<SubprocessResult, Error>
                    do {
                        outcome = .success(try await Subprocess.run(
                            executable: copy?.executable ?? fallbackExecutable,
                            arguments: argv,
                            environment: environment,
                            onStdoutLine: { line in
                                guard let event = YtDlpEvent(line: line) else { return }
                                sawEvent.withLock { $0 = true }
                                continuation.yield(.event(event))
                            }
                        ))
                    } catch {
                        outcome = .failure(error)
                    }
                    if attempt < 3, let selection, let failed = copy, !Task.isCancelled,
                       Self.looksLikeLaunchFailure(outcome, sawEvent: sawEvent.withLock { $0 }),
                       let next = await selection.fallBack(from: failed), next != failed {
                        copy = next
                        continue
                    }
                    switch outcome {
                    case .success(let result):
                        continuation.yield(.exited(YtDlpExit(termination: result.termination, stderr: result.stderr)))
                        continuation.finish()
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    }
                    return
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Whether a run may have failed because yt-dlp itself did not start, rather than because of
    /// the video: it could not be executed, or it ended (crashed, or the frozen Python failed to
    /// start, exit 255) before printing any event and without an `ERROR:` line of its own. A usage
    /// error (exit 2) means it started. The fallback still checks the copy with `--version`
    /// before switching.
    static func looksLikeLaunchFailure(_ outcome: Result<SubprocessResult, Error>, sawEvent: Bool) -> Bool {
        guard case .success(let result) = outcome else { return true }
        guard !sawEvent, !result.stderr.contains("ERROR:") else { return false }
        switch result.termination {
        case .exited(let status): return status != 0 && status != 2
        case .signaled: return true
        }
    }
}
