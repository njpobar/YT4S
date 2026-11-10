import Foundation
import Testing
@testable import YT4SCore

/// Snip against the ffmpeg and ffprobe bundled in a built YT4S.app: a short MP4 and MP3 (made
/// with that same ffmpeg, so no network) are snipped by the real `Snipper`, and the Snipped
/// copies' duration, codecs, resolution, metadata, cover art and tags are checked. Opt-in (see
/// `LiveTests`):
///
///     YT4S_LIVE_APP=build/YT4S.app swift test --filter LiveSnipTests
@Suite(.live, .serialized, .timeLimit(.minutes(2)))
struct LiveSnipTests {
    @Test func aVideoIsCutFrameExactlyAndKeepsItsResolutionAndMetadata() async throws {
        let sandbox = try Sandbox()
        let original = sandbox.folder.appendingPathComponent("Talk.mp4")
        // 4 s at 30 fps: 120 frames, 640x360, with AAC audio and MP4 metadata.
        try await sandbox.ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
            "-c:v", "h264_videotoolbox", "-c:a", "aac", "-shortest",
            "-metadata", "title=Talk", "-metadata", "artist=Channel", "-metadata", "date=20050424",
            original.path,
        ])
        let video = SavedVideo(videoID: "jNQXAC9IVRw", format: .video)
        try sandbox.downloadFolder.tag(original, with: video)
        let originalBytes = try Data(contentsOf: original)

        let copy = try await sandbox.snip(original, video: video, cut: Cut(start: 1, end: 2), duration: 4)

        #expect(copy == sandbox.folder.appendingPathComponent("Talk (snipped).mp4"))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(sandbox.downloadFolder.savedVideo(ofFileAt: copy) == video)
        let probe = try await sandbox.probe(copy)
        #expect(probe.videoFrames == 90, "\(probe)")
        #expect(abs(probe.duration - 3) < 0.05, "\(probe)")
        #expect(probe.streams.contains { $0.codec == "h264" && $0.width == 640 && $0.height == 360 }, "\(probe)")
        #expect(probe.streams.contains { $0.codec == "aac" }, "\(probe)")
        #expect(probe.tags["title"] == "Talk", "\(probe)")
        #expect(probe.tags["artist"] == "Channel", "\(probe)")
        #expect(probe.tags["date"] == "20050424", "\(probe)")
    }

    @Test func anMP3IsReEncodedAt320KAndKeepsItsTagsAndCoverArt() async throws {
        let sandbox = try Sandbox()
        let cover = sandbox.folder.appendingPathComponent("cover.jpg")
        let original = sandbox.folder.appendingPathComponent("Song.mp3")
        try await sandbox.ffmpeg(["-f", "lavfi", "-i", "color=c=red:size=64x64", "-frames:v", "1", cover.path])
        try await sandbox.ffmpeg([
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-i", cover.path,
            "-map", "0:a", "-map", "1:v", "-c:a", "libmp3lame", "-b:a", "128k",
            "-c:v", "copy", "-disposition:v", "attached_pic", "-id3v2_version", "3",
            "-metadata", "title=Song", "-metadata", "artist=Band",
            original.path,
        ])
        try FileManager.default.removeItem(at: cover)
        let video = SavedVideo(videoID: "jNQXAC9IVRw", format: .mp3)
        try sandbox.downloadFolder.tag(original, with: video)
        let originalBytes = try Data(contentsOf: original)

        let copy = try await sandbox.snip(original, video: video, cut: Cut(start: 3, end: 4), duration: 4)

        #expect(copy == sandbox.folder.appendingPathComponent("Song (snipped).mp3"))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(sandbox.downloadFolder.savedVideo(ofFileAt: copy) == video)
        let probe = try await sandbox.probe(copy)
        #expect(probe.formatName == "mp3", "\(probe)")
        #expect(abs(probe.duration - 3) < 0.05, "\(probe)")
        #expect(probe.streams.contains { $0.codec == "mp3" && $0.bitRate == 320_000 }, "\(probe)")
        #expect(probe.streams.contains { $0.codec == "mjpeg" && $0.attachedPicture }, "\(probe)")
        #expect(probe.tags["title"] == "Song", "\(probe)")
        #expect(probe.tags["artist"] == "Band", "\(probe)")
    }

    // MARK: - Bundled tools

    struct Sandbox {
        let folder: URL
        let tools: BundledTools

        var downloadFolder: DownloadFolder { DownloadFolder(url: folder) }

        init() throws {
            tools = try #require(LiveTests.tools)
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("yt4s-live-snip-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func ffmpeg(_ arguments: [String]) async throws {
            let result = try await Subprocess.run(
                executable: tools.ffmpegDirectory.appendingPathComponent("ffmpeg"),
                arguments: ["-hide_banner", "-v", "error", "-nostdin", "-y"] + arguments
            )
            #expect(result.termination == .exited(0), "\(result.stderr)")
        }

        func snip(_ original: URL, video: SavedVideo, cut: Cut, duration: Double) async throws -> URL {
            let plan = SnipPlan(duration: duration, cuts: [cut])
            var saved: URL?
            var fractions: [Double] = []
            for try await update in Snipper(tools: tools).snip(original, video: video, plan: plan, in: downloadFolder) {
                switch update {
                case .progress(let fraction): fractions.append(fraction)
                case .saved(let copy): saved = copy
                }
            }
            #expect(!fractions.isEmpty)
            #expect(fractions == fractions.sorted())
            return try #require(saved)
        }

        struct Stream {
            var codec: String
            var width: Int?
            var height: Int?
            var bitRate: Int?
            var attachedPicture: Bool
        }

        struct Probe {
            var formatName: String
            var duration: Double
            var videoFrames: Int?
            var streams: [Stream]
            var tags: [String: String]
        }

        func probe(_ file: URL) async throws -> Probe {
            let result = try await Subprocess.run(
                executable: tools.ffmpegDirectory.appendingPathComponent("ffprobe"),
                arguments: ["-v", "error", "-of", "json", "-count_frames", "-show_format", "-show_streams", file.path]
            )
            #expect(result.termination == .exited(0), "\(result.stderr)")

            struct Output: Decodable {
                struct Format: Decodable {
                    var format_name: String
                    var duration: String
                    var tags: [String: String]?
                }
                struct Stream: Decodable {
                    var codec_type: String
                    var codec_name: String?
                    var width: Int?
                    var height: Int?
                    var bit_rate: String?
                    var nb_read_frames: String?
                    var disposition: [String: Int]?
                }
                var format: Format
                var streams: [Stream]
            }
            let output = try JSONDecoder().decode(Output.self, from: Data(result.stdout.utf8))
            let video = output.streams.first { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }
            return Probe(
                formatName: output.format.format_name,
                duration: Double(output.format.duration) ?? 0,
                videoFrames: video?.nb_read_frames.flatMap(Int.init),
                streams: output.streams.map {
                    Stream(
                        codec: $0.codec_name ?? "", width: $0.width, height: $0.height,
                        bitRate: $0.bit_rate.flatMap(Int.init), attachedPicture: $0.disposition?["attached_pic"] == 1
                    )
                },
                tags: Dictionary(output.format.tags?.map { ($0.key.lowercased(), $0.value) } ?? [], uniquingKeysWith: { first, _ in first })
            )
        }
    }
}
