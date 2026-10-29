import Foundation
@testable import YT4SCore

/// Test harness around `Fixtures/fake-yt-dlp`.
///
/// Each instance gets its own temp Download folder and an argv log, and runs the fake
/// through `YtDlpCommand` + `Subprocess`, i.e. the same path the app uses for the real binary.
struct FakeYtDlp {
    let executable: URL
    let downloadFolder: URL
    let argvLog: URL
    let tools: BundledTools

    init() throws {
        guard let url = Bundle.module.url(forResource: "fake-yt-dlp", withExtension: nil, subdirectory: "Fixtures") else {
            throw FixtureError.missing("Fixtures/fake-yt-dlp")
        }
        // SwiftPM resource copies are not guaranteed to keep the executable bit.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        executable = url

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-tests-\(UUID().uuidString)", isDirectory: true)
        downloadFolder = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        argvLog = root.appendingPathComponent("argv.log")

        tools = BundledTools(
            ytDlp: url,
            ffmpegDirectory: URL(fileURLWithPath: "/nonexistent/bin", isDirectory: true),
            deno: URL(fileURLWithPath: "/nonexistent/bin/deno")
        )
    }

    /// Runs the fake with the app's mandatory flags prepended to `arguments`.
    func run(
        _ arguments: [String],
        scenario: String,
        extraEnvironment: [String: String] = [:]
    ) async throws -> SubprocessResult {
        try await runRaw(YtDlpCommand(tools: tools).arguments(arguments), scenario: scenario, extraEnvironment: extraEnvironment)
    }

    /// A real `YtDlpRunner` with the fake injected as the yt-dlp executable.
    func runner(scenario: String, extraEnvironment: [String: String] = [:]) -> YtDlpRunner {
        YtDlpRunner(tools: tools, environment: environment(scenario: scenario, extraEnvironment: extraEnvironment))
    }

    func environment(scenario: String, extraEnvironment: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["YT4S_FAKE_SCENARIO"] = scenario
        environment["YT4S_FAKE_ARGV_LOG"] = argvLog.path
        environment.merge(extraEnvironment) { _, new in new }
        return environment
    }

    /// Runs the fake with exactly `arguments`, skipping `YtDlpCommand`.
    func runRaw(
        _ arguments: [String],
        scenario: String,
        extraEnvironment: [String: String] = [:]
    ) async throws -> SubprocessResult {
        try await Subprocess.run(
            executable: executable,
            arguments: arguments,
            environment: environment(scenario: scenario, extraEnvironment: extraEnvironment)
        )
    }

    /// Pauses every video right after it prints progress step `percent` (0, 25, 50 or 75) until
    /// `release()`, so a test can look at or act on a run mid-download without racing a timer.
    func hold(at percent: Int) -> Hold {
        Hold(percent: percent, releaseFile: argvLog.deletingLastPathComponent().appendingPathComponent("release-\(percent)"))
    }

    struct Hold {
        let percent: Int
        let releaseFile: URL

        var environment: [String: String] {
            ["YT4S_FAKE_HOLD_AT": String(percent), "YT4S_FAKE_RELEASE_FILE": releaseFile.path]
        }

        func release() throws { try Data().write(to: releaseFile) }
    }

    /// Where the fake writes its pid on start, when `YT4S_FAKE_PID_FILE` is set to it.
    var pidFile: URL { argvLog.deletingLastPathComponent().appendingPathComponent("pid") }

    /// The pid the last run wrote to `pidFile`, once it has started.
    func pid() -> pid_t? {
        (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// argv of the last run. The fake writes each element NUL-terminated.
    func loggedArgv() throws -> [String] {
        try String(contentsOf: argvLog, encoding: .utf8)
            .split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }
}

enum FixtureError: Error {
    case missing(String)
}
