import Foundation

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
    public func run(_ arguments: [String]) -> AsyncThrowingStream<YtDlpRunUpdate, Error> {
        let argv = YtDlpCommand(tools: tools).arguments(arguments)
        let executable = selection?.copy.executable ?? tools.ytDlp
        let environment = environment
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await Subprocess.run(
                        executable: executable,
                        arguments: argv,
                        environment: environment,
                        onStdoutLine: { line in
                            if let event = YtDlpEvent(line: line) { continuation.yield(.event(event)) }
                        }
                    )
                    continuation.yield(.exited(YtDlpExit(termination: result.termination, stderr: result.stderr)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
