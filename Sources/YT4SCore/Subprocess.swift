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
/// Cancelling the calling task sends SIGTERM to the child.
public enum Subprocess {
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
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

        let stdoutData = PipeCollector(stdoutPipe.fileHandleForReading)
        let stderrData = PipeCollector(stderrPipe.fileHandleForReading)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SubprocessResult, Error>) in
                process.terminationHandler = { process in
                    let termination: SubprocessTermination = switch process.terminationReason {
                    case .uncaughtSignal: .signaled(process.terminationStatus)
                    case .exit: .exited(process.terminationStatus)
                    @unknown default: .exited(process.terminationStatus)
                    }
                    continuation.resume(returning: SubprocessResult(
                        termination: termination,
                        stdout: String(decoding: stdoutData.finish(), as: UTF8.self),
                        stderr: String(decoding: stderrData.finish(), as: UTF8.self)
                    ))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Drains a pipe on a background thread so a chatty child never blocks on a full pipe buffer.
private final class PipeCollector: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    /// Blocks until the writer side closes, then returns everything read.
    func finish() -> Data {
        done.wait()
        return data
    }
}
