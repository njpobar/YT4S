import Foundation

/// How a child process ended.
public enum SubprocessTermination: Equatable, Sendable {
    /// Normal exit with this status code.
    case exited(Int32)
    /// Killed by this signal (a crash, or our own cancellation).
    case signaled(Int32)
}

public struct SubprocessResult: Sendable {
    public let termination: SubprocessTermination
    public let stdout: String
    public let stderr: String

    public var stdoutLines: [String] { Self.lines(stdout) }
    public var stderrLines: [String] { Self.lines(stderr) }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

/// Runs an executable to completion and captures its output.
///
/// Cancelling the calling task sends SIGTERM to the child and everything it started.
public enum Subprocess {
    /// - Parameter onStdoutLine: called on a background thread with each complete stdout line
    ///   (without the newline) as soon as it is written, in order, all before `run` returns.
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutData = PipeCollector(stdoutPipe.fileHandleForReading, onLine: onStdoutLine)
        let stderrData = PipeCollector(stderrPipe.fileHandleForReading)
        let cancellation = GroupTermination()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SubprocessResult, Error>) in
                process.terminationHandler = { process in
                    let termination: SubprocessTermination = switch process.terminationReason {
                    case .uncaughtSignal: .signaled(process.terminationStatus)
                    case .exit: .exited(process.terminationStatus)
                    @unknown default: .exited(process.terminationStatus)
                    }
                    cancellation.sweep()
                    continuation.resume(returning: SubprocessResult(
                        termination: termination,
                        stdout: String(decoding: stdoutData.finish(), as: UTF8.self),
                        stderr: String(decoding: stderrData.finish(), as: UTF8.self)
                    ))
                }
                do {
                    try process.run()
                    // `onCancel` only terminates a running child: a cancel that landed before
                    // launch would otherwise let it run to completion. The flag is set before
                    // `onCancel` runs, so one of the two always sees it.
                    if Task.isCancelled { cancellation.terminate(process) }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { cancellation.terminate(process) }
        }
    }
}

/// Cancel's SIGTERM, sent to the child's whole process group rather than just the child:
/// yt-dlp's helpers (ffmpeg) would otherwise keep running and hold the output pipes open, so
/// `run` (and Cancel) would wait for them to finish. `Process` makes each child the leader of
/// its own group.
///
/// A helper being forked at the moment of the signal can escape it, so once the child itself has
/// ended the group is signalled again. That is safe: a group ID is not reused while any process
/// of the group is alive, and with none left the signal goes nowhere.
private final class GroupTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var groupLeader: pid_t?

    func terminate(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0, getpgid(pid) == pid else {
            process.terminate()
            return
        }
        lock.withLock { groupLeader = pid }
        kill(-pid, SIGTERM)
    }

    /// Called once the child has exited: signals whatever is left of its group after a Cancel.
    func sweep() {
        guard let pid = lock.withLock({ groupLeader }) else { return }
        kill(-pid, SIGTERM)
    }
}

/// Drains a pipe on a background thread so a chatty child never blocks on a full pipe buffer,
/// optionally reporting each complete line as it arrives.
private final class PipeCollector: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ handle: FileHandle, onLine: (@Sendable (String) -> Void)? = nil) {
        Thread.detachNewThread { [self] in
            var lineStart = 0
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                guard let onLine else { continue }
                while let newline = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                    onLine(String(decoding: data[lineStart..<newline], as: UTF8.self))
                    lineStart = newline + 1
                }
            }
            if let onLine, lineStart < data.count {
                onLine(String(decoding: data[lineStart...], as: UTF8.self))
            }
            done.signal()
        }
    }

    /// Blocks until the writer side closes, then returns everything read.
    func finish() -> Data {
        done.wait()
        return data
    }
}
