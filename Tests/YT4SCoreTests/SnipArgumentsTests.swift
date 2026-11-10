import Foundation
import Testing
@testable import YT4SCore

/// The ffmpeg run that makes a Snipped copy: frame-exact trims of every kept span, joined, then
/// re-encoded (video with the hardware H.264 encoder, MP3 at 320K), metadata and cover art kept.
/// Every join (and every edge a Cut leaves at the copy's start or end) fades the audio over
/// `joinFade` (20 ms) so it does not click.
@Suite struct SnipArgumentsTests {
    private let input = URL(fileURLWithPath: "/tmp/YT4S/Talk.mp4")
    private let output = URL(fileURLWithPath: "/tmp/YT4S/.yt4s-incomplete/x.mp4")

    @Test func aVideoKeepsBothSidesOfAMiddleCutReEncodedWithItsMetadata() {
        let plan = SnipPlan(duration: 60, cuts: [Cut(start: 10, end: 25)])

        #expect(SnipArguments.arguments(input: input, output: output, format: .video, plan: plan) == [
            "-hide_banner", "-nostdin", "-v", "error", "-nostats", "-progress", "pipe:1", "-y",
            "-i", "/tmp/YT4S/Talk.mp4",
            "-filter_complex",
            "[0:v]trim=start=0:end=10,setpts=PTS-STARTPTS[v0];"
                + "[0:a]atrim=start=0:end=10,asetpts=PTS-STARTPTS,afade=t=out:st=9.98:d=0.02[a0];"
                + "[0:v]trim=start=25,setpts=PTS-STARTPTS[v1];"
                + "[0:a]atrim=start=25,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.02[a1];"
                + "[v0][a0][v1][a1]concat=n=2:v=1:a=1[v][a]",
            "-map", "[v]", "-map", "[a]", "-map_metadata", "0",
            "-c:v", "h264_videotoolbox", "-q:v", "70",
            "-c:a", "aac", "-b:a", "256k",
            "-movflags", "+faststart",
            "/tmp/YT4S/.yt4s-incomplete/x.mp4",
        ])
    }

    @Test func anMP3KeepsItsCoverArtAndTagsAt320K() {
        let plan = SnipPlan(duration: 60, cuts: [Cut(start: 50, end: 60)])

        #expect(SnipArguments.arguments(input: input, output: output, format: .mp3, plan: plan) == [
            "-hide_banner", "-nostdin", "-v", "error", "-nostats", "-progress", "pipe:1", "-y",
            "-i", "/tmp/YT4S/Talk.mp4",
            "-filter_complex",
            "[0:a]atrim=start=0:end=50,asetpts=PTS-STARTPTS,afade=t=out:st=49.98:d=0.02[a0];[a0]concat=n=1:v=0:a=1[a]",
            "-map", "[a]", "-map", "0:v?", "-map_metadata", "0",
            "-c:a", "libmp3lame", "-b:a", "320k",
            "-c:v", "copy", "-id3v2_version", "3",
            "/tmp/YT4S/.yt4s-incomplete/x.mp4",
        ])
    }

    @Test func timesKeepMicrosecondsWithoutTrailingZeros() {
        let plan = SnipPlan(duration: 60, cuts: [Cut(start: 1.25, end: 2.0000004)])
        let filter = SnipArguments.arguments(input: input, output: output, format: .mp3, plan: plan)

        #expect(filter.contains(
            "[0:a]atrim=start=0:end=1.25,asetpts=PTS-STARTPTS,afade=t=out:st=1.23:d=0.02[a0];"
                + "[0:a]atrim=start=2,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.02[a1];[a0][a1]concat=n=2:v=0:a=1[a]"
        ))
    }

    @Test func aSpanBetweenTwoJoinsFadesInAndOut() {
        let plan = SnipPlan(duration: 60, cuts: [Cut(start: 0, end: 5), Cut(start: 20, end: 30), Cut(start: 50, end: 60)])
        let filter = SnipArguments.arguments(input: input, output: output, format: .mp3, plan: plan)

        #expect(filter.contains(
            "[0:a]atrim=start=5:end=20,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.02,afade=t=out:st=14.98:d=0.02[a0];"
                + "[0:a]atrim=start=30:end=50,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.02,afade=t=out:st=19.98:d=0.02[a1];"
                + "[a0][a1]concat=n=2:v=0:a=1[a]"
        ))
    }

    @Test func theEndsOfTheFileAreNotJoinsAndDoNotFade() {
        let plan = SnipPlan(duration: 60, cuts: [Cut(start: 20, end: 30)])
        let filter = SnipArguments.arguments(input: input, output: output, format: .mp3, plan: plan)

        #expect(filter.contains(
            "[0:a]atrim=start=0:end=20,asetpts=PTS-STARTPTS,afade=t=out:st=19.98:d=0.02[a0];"
                + "[0:a]atrim=start=30,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.02[a1];[a0][a1]concat=n=2:v=0:a=1[a]"
        ))
    }

    @Test func aSpanShorterThanTwoFadesSharesItsLengthBetweenThem() {
        let plan = SnipPlan(duration: 60, cuts: [Cut(start: 0, end: 10), Cut(start: 10.03, end: 60)])
        let filter = SnipArguments.arguments(input: input, output: output, format: .mp3, plan: plan)

        #expect(filter.contains(
            "[0:a]atrim=start=10:end=10.03,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.015,afade=t=out:st=0.015:d=0.015[a0];"
                + "[a0]concat=n=1:v=0:a=1[a]"
        ))
    }

    @Test(arguments: [
        ("out_time_us=1500000", 0.5),
        ("out_time_us=0", 0),
        ("out_time_us=9000000", 1),
    ])
    func progressIsTheTimeWrittenOverTheKeptDuration(line: String, fraction: Double) {
        #expect(SnipArguments.fraction(ofProgressLine: line, keptDuration: 3) == fraction)
    }

    @Test(arguments: ["out_time_us=N/A", "out_time=00:00:01.500000", "progress=continue", "frame=12"])
    func otherProgressLinesSayNothing(line: String) {
        #expect(SnipArguments.fraction(ofProgressLine: line, keptDuration: 3) == nil)
    }
}
