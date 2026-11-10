import Foundation

/// Builds the bundled ffmpeg's argv for a Snip and reads its progress.
///
/// Every kept span is trimmed out of the original and the spans are joined, so Cuts are
/// frame-exact; that needs a re-encode: video with the hardware `h264_videotoolbox` (same
/// resolution), audio as AAC, or MP3. Each is encoded at the original's own bitrate (an MP3 at the
/// nearest standard one at or above it), so the copy is no bigger per second than the original;
/// when that is not known, at a high quality instead (MP3 320K). Metadata is copied from the original, and an
/// MP3's cover art (its attached picture) is copied as is. The audio fades over `joinFade`
/// seconds on each side of every Cut (out before it, in after it), so no join clicks, nor a
/// copy that now starts or stops mid-sound; the original file's own start and end are left as is.
public enum SnipArguments {
    /// The audio fade on each side of a join, in seconds.
    public static let joinFade = 0.02

    public static func arguments(input: URL, output: URL, format: Format, plan: SnipPlan, bitrates: SourceBitrates = SourceBitrates()) -> [String] {
        let spans = plan.keptSpans
        var filters: [String] = []
        var joined = ""
        for (index, span) in spans.enumerated() {
            // A span running to the end of the file is left open, so rounding never drops its last frame.
            let range = "start=\(seconds(span.start))" + (span.end >= plan.duration ? "" : ":end=\(seconds(span.end))")
            if format == .video {
                filters.append("[0:v]trim=\(range),setpts=PTS-STARTPTS[v\(index)]")
                joined += "[v\(index)]"
            }
            // Shorter than two fades: each gets half the span.
            let fade = min(joinFade, span.length / 2)
            var audio = "[0:a]atrim=\(range),asetpts=PTS-STARTPTS"
            if span.start > 0 { audio += ",afade=t=in:st=0:d=\(seconds(fade))" }
            if span.end < plan.duration { audio += ",afade=t=out:st=\(seconds(span.length - fade)):d=\(seconds(fade))" }
            filters.append(audio + "[a\(index)]")
            joined += "[a\(index)]"
        }
        let common = [
            "-hide_banner", "-nostdin", "-v", "error", "-nostats", "-progress", "pipe:1", "-y",
            "-i", input.path,
            "-filter_complex",
        ]
        switch format {
        case .video:
            filters.append(joined + "concat=n=\(spans.count):v=1:a=1[v][a]")
            return common + [filters.joined(separator: ";")] + [
                "-map", "[v]", "-map", "[a]", "-map_metadata", "0",
                "-c:v", "h264_videotoolbox",
            ] + (bitrates.video.map { ["-b:v", String($0)] } ?? ["-q:v", "70"]) + [
                "-c:a", "aac", "-b:a", bitrates.audio.map { "\(max(($0 + 500) / 1000, 32))k" } ?? "256k",
                "-movflags", "+faststart",
                output.path,
            ]
        case .mp3:
            filters.append(joined + "concat=n=\(spans.count):v=0:a=1[a]")
            return common + [filters.joined(separator: ";")] + [
                "-map", "[a]", "-map", "0:v?", "-map_metadata", "0",
                "-c:a", "libmp3lame", "-b:a", "\(mp3Kilobits(atLeast: bitrates.audio))k",
                "-c:v", "copy", "-id3v2_version", "3",
                output.path,
            ]
        }
    }

    /// How far a run is, from one of its `-progress` lines: the output time written so far over
    /// the Snipped copy's length. `nil` for every other line.
    public static func fraction(ofProgressLine line: String, keptDuration: Double) -> Double? {
        guard line.hasPrefix("out_time_us="), let microseconds = Double(line.dropFirst("out_time_us=".count)),
              keptDuration > 0 else { return nil }
        return min(max(microseconds / 1_000_000 / keptDuration, 0), 1)
    }

    /// The MP3 bitrates (kbit/s) an encoder can write.
    private static let mp3Kilobits = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]

    /// The smallest standard MP3 bitrate that keeps `bitsPerSecond` (rounded to the kilobit), or
    /// 320 when it is unknown or higher.
    private static func mp3Kilobits(atLeast bitsPerSecond: Int?) -> Int {
        guard let bitsPerSecond else { return 320 }
        let kilobits = (bitsPerSecond + 500) / 1000
        return mp3Kilobits.first { $0 >= kilobits } ?? 320
    }

    /// Seconds to the microsecond, without trailing zeros (`10`, `1.25`).
    private static func seconds(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// The original's video and audio bitrates in bits per second, as ffprobe reports them; `nil`
/// where unknown.
public struct SourceBitrates: Equatable, Sendable {
    public var video: Int?
    public var audio: Int?

    public init(video: Int? = nil, audio: Int? = nil) {
        self.video = video
        self.audio = audio
    }

    /// From `ffprobe -of json -show_streams`: the first video stream that is a picture (not
    /// an MP3's cover art) and the first audio stream. Unknown when the output does not parse.
    public init(ffprobeJSON data: Data) {
        struct Output: Decodable {
            struct Stream: Decodable {
                var codec_type: String
                var bit_rate: String?
                var disposition: [String: Int]?
            }
            var streams: [Stream]
        }
        let streams = (try? JSONDecoder().decode(Output.self, from: data))?.streams ?? []
        func bitrate(of type: String) -> Int? {
            streams.first { $0.codec_type == type && $0.disposition?["attached_pic"] != 1 }?.bit_rate.flatMap { Int($0) }
        }
        self.init(video: bitrate(of: "video"), audio: bitrate(of: "audio"))
    }
}
