import Foundation
import Testing
@testable import YT4SCore

/// The contract between YT4S and the yt-dlp + ffmpeg bundled in a built YT4S.app: one short,
/// stable public video goes through the real Queue as Video and as MP3, and every line, file and
/// tag the app relies on is checked. `scripts/release.sh` runs this against the app it just built
/// and aborts the release on failure. Opt-in (see `LiveTests`):
///
///     YT4S_LIVE_APP=build/YT4S.app swift test --filter LiveContractTests
@MainActor @Suite(.live, .serialized)
struct LiveContractTests {
    /// "Me at the zoo": the first YouTube video, 19 s, unchanged since 2005.
    static let videoID = "jNQXAC9IVRw"
    static let link = "https://www.youtube.com/watch?v=\(videoID)"

    @Test(.timeLimit(.minutes(5)))
    func video() async throws {
        let run = try await download(DownloadOptions(format: .video, quality: .p720, naming: .dateTitle))

        let file = run.folder.appendingPathComponent("2005-04-24 - Me at the zoo.mp4")
        #expect(run.state == .finished(file: file))
        expectMachineOutput(run, fileExtension: "mp4")
        expectTagged(file, format: "video")

        let probe = try await probe(file)
        #expect(probe.formatName.contains("mp4"), "\(probe)")
        #expect(probe.streams.contains(Stream(type: "video", codec: "h264", attachedPicture: false)), "\(probe)")
        #expect(probe.streams.contains(Stream(type: "audio", codec: "aac", attachedPicture: false)), "\(probe)")
    }

    @Test(.timeLimit(.minutes(5)))
    func mp3() async throws {
        let run = try await download(DownloadOptions(format: .mp3, quality: .best, naming: .title))

        let file = run.folder.appendingPathComponent("Me at the zoo.mp3")
        #expect(run.state == .finished(file: file))
        expectMachineOutput(run, fileExtension: "mp3")
        expectTagged(file, format: "mp3")

        let probe = try await probe(file)
        #expect(probe.formatName == "mp3", "\(probe)")
        #expect(probe.streams.contains(Stream(type: "audio", codec: "mp3", attachedPicture: false)), "\(probe)")
        // The cover art: the thumbnail, converted to JPEG and embedded as an attached picture.
        #expect(probe.streams.contains(Stream(type: "video", codec: "mjpeg", attachedPicture: true)), "\(probe)")
        #expect(probe.tags["title"] == "Me at the zoo", "\(probe)")
    }

    // MARK: - Download through the real Queue

    struct Run {
        var folder: URL
        var state: QueueItemState
        /// Everything the bundled yt-dlp printed on stdout during the run.
        var stdout: [String]
    }

    /// Downloads the video like the app does (MainWindowModel -> Queue -> YtDlpRunner), with the
    /// bundled yt-dlp behind a wrapper that keeps a copy of its stdout.
    private func download(_ options: DownloadOptions) async throws -> Run {
        let tools = try #require(LiveTests.tools)
        #expect(FileManager.default.isExecutableFile(atPath: tools.ytDlp.path), "no yt-dlp in \(LiveTests.app?.path ?? "")")

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt4s-live-contract-\(UUID().uuidString)", isDirectory: true)
        let folder = sandbox.appendingPathComponent("Downloads", isDirectory: true)
        let stdoutLog = sandbox.appendingPathComponent("yt-dlp.stdout")
        let wrapper = sandbox.appendingPathComponent("yt-dlp")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try """
            #!/bin/bash
            set -o pipefail
            "\(tools.ytDlp.path)" "$@" | tee -a "\(stdoutLog.path)"
            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        var wrapped = tools
        wrapped.ytDlp = wrapper
        let queue = Queue(
            runner: YtDlpRunner(tools: wrapped),
            partialFilesFolder: sandbox.appendingPathComponent("partial", isDirectory: true)
        )
        let model = MainWindowModel(queue: queue, downloadFolder: folder)
        model.options = options
        model.pasteText = Self.link
        model.download()
        await model.waitUntilListed()
        await queue.waitUntilIdle()
        #expect(model.errorMessage == nil)

        let item = try #require(queue.items.first)
        #expect(queue.items.count == 1)
        if case .failed(let failure) = item.state {
            Issue.record("download failed (\(failure.category)): \(failure.details)")
        }
        let stdout = (try? String(contentsOf: stdoutLog, encoding: .utf8)) ?? ""
        return Run(folder: folder, state: item.state, stdout: stdout.split(separator: "\n").map(String.init))
    }

    // MARK: - Assertions

    /// Every `YT4S-` line parses, and each kind the Queue needs came out with real values.
    private func expectMachineOutput(_ run: Run, fileExtension: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let ours = run.stdout.filter { $0.hasPrefix("YT4S-") }
        let events = ours.compactMap(YtDlpEvent.init(line:))
        #expect(events.count == ours.count, "unparsable lines: \(ours.filter { YtDlpEvent(line: $0) == nil })", sourceLocation: sourceLocation)

        let videos = events.compactMap { if case .video(let info) = $0 { info } else { nil } }
        #expect(videos.map(\.id) == [Self.videoID], sourceLocation: sourceLocation)
        #expect(videos.first?.title == "Me at the zoo", sourceLocation: sourceLocation)
        #expect(videos.first?.formatIDs.isEmpty == false, sourceLocation: sourceLocation)
        #expect(videos.first?.partSizes.contains(nil) == false, "sizes unknown: \(videos)", sourceLocation: sourceLocation)

        let details = events.compactMap { if case .details(let details) = $0 { details } else { nil } }
        #expect(details == [VideoDetails(id: Self.videoID, title: "Me at the zoo", channel: "jawed", uploadDate: "20050424")], sourceLocation: sourceLocation)

        // The progress template: ticks for the requested parts, with byte counts, ending finished.
        let ticks = events.compactMap { if case .progress(let tick) = $0 { tick } else { nil } }
        #expect(!ticks.isEmpty, "no YT4S-PROGRESS lines", sourceLocation: sourceLocation)
        #expect(ticks.allSatisfy { $0.videoID == Self.videoID }, sourceLocation: sourceLocation)
        #expect(Set(ticks.map(\.formatID)).isSubset(of: Set(videos.first?.formatIDs ?? [])), "\(ticks.map(\.formatID))", sourceLocation: sourceLocation)
        #expect(ticks.allSatisfy { $0.downloadedBytes != nil }, sourceLocation: sourceLocation)
        #expect(ticks.contains { $0.totalBytes != nil || $0.totalBytesEstimate != nil }, sourceLocation: sourceLocation)
        #expect(ticks.last?.status == .finished, sourceLocation: sourceLocation)
        let finished = ticks.filter { $0.status == .finished }
        #expect(finished.allSatisfy { ($0.downloadedBytes ?? 0) > 0 && $0.downloadedBytes == $0.totalBytes }, "\(finished)", sourceLocation: sourceLocation)

        // The file line names what yt-dlp left in the hidden incomplete folder, before placing.
        let files = events.compactMap { if case .file(let id, let path) = $0 { (id, path) } else { nil } }
        #expect(files.count == 1, sourceLocation: sourceLocation)
        if let (id, path) = files.first {
            #expect(id == Self.videoID, sourceLocation: sourceLocation)
            #expect(path.hasSuffix("/\(DownloadFolder.incompleteFolderName)/\(Self.videoID).\(fileExtension)"), "\(path)", sourceLocation: sourceLocation)
        }
    }

    /// The raw extended attributes skip detection reads, checked byte for byte.
    private func expectTagged(_ file: URL, format: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(FileManager.default.fileExists(atPath: file.path), "\(file.path) missing", sourceLocation: sourceLocation)
        #expect(xattr("com.yt4s.videoid", of: file) == Self.videoID, sourceLocation: sourceLocation)
        #expect(xattr("com.yt4s.format", of: file) == format, sourceLocation: sourceLocation)
    }

    private func xattr(_ name: String, of file: URL) -> String? {
        let size = getxattr(file.path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(file.path, name, &bytes, size, 0, 0) == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - ffprobe (the bundled one)

    struct Stream: Equatable, CustomStringConvertible {
        var type: String
        var codec: String
        var attachedPicture: Bool
        var description: String { "\(type)/\(codec)\(attachedPicture ? " (attached picture)" : "")" }
    }

    struct Probe: CustomStringConvertible {
        var formatName: String
        var streams: [Stream]
        var tags: [String: String]
        var description: String { "\(formatName): \(streams), tags \(tags)" }
    }

    private func probe(_ file: URL) async throws -> Probe {
        let tools = try #require(LiveTests.tools)
        let result = try await Subprocess.run(
            executable: tools.ffmpegDirectory.appendingPathComponent("ffprobe"),
            arguments: ["-v", "error", "-of", "json", "-show_format", "-show_streams", file.path]
        )
        #expect(result.termination == .exited(0), "\(result.stderr)")

        struct Output: Decodable {
            struct Format: Decodable {
                var format_name: String
                var tags: [String: String]?
            }
            struct Stream: Decodable {
                var codec_type: String
                var codec_name: String?
                var disposition: [String: Int]?
            }
            var format: Format
            var streams: [Stream]
        }
        let output = try JSONDecoder().decode(Output.self, from: Data(result.stdout.utf8))
        return Probe(
            formatName: output.format.format_name,
            streams: output.streams.map {
                Stream(type: $0.codec_type, codec: $0.codec_name ?? "", attachedPicture: $0.disposition?["attached_pic"] == 1)
            },
            tags: Dictionary(output.format.tags?.map { ($0.key.lowercased(), $0.value) } ?? [], uniquingKeysWith: { first, _ in first })
        )
    }
}
