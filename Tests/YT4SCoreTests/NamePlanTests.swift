import Foundation
import Testing
@testable import YT4SCore

@Suite("Naming pattern rendering")
struct NamePlanTests {
    let zoo = VideoDetails(id: "jNQXAC9IVRw", title: "Me at the zoo", channel: "jawed", uploadDate: "20050424")

    func path(
        _ pattern: NamingPattern,
        _ video: VideoDetails,
        origin: VideoOrigin = .link,
        ext: String = "mp4",
        idSuffix: Bool = false
    ) -> String {
        NamePlan(pattern: pattern, video: video, origin: origin)
            .relativePath(videoID: video.id, fileExtension: ext, withIDSuffix: idSuffix)
    }

    @Test func titlePresetForASingleLinkIsFlat() {
        #expect(path(.title, zoo) == "Me at the zoo.mp4")
    }

    @Test func channelTitlePresetPutsTheVideosChannelFirst() {
        #expect(path(.channelTitle, zoo) == "jawed - Me at the zoo.mp4")
    }

    @Test func dateTitlePresetPutsTheUploadDateFirst() {
        #expect(path(.dateTitle, zoo) == "2005-04-24 - Me at the zoo.mp4")
    }

    @Test func aMissingChannelOrDateLeavesJustTheTitle() {
        let bare = VideoDetails(id: "jNQXAC9IVRw", title: "Me at the zoo")
        #expect(path(.channelTitle, bare) == "Me at the zoo.mp4")
        #expect(path(.dateTitle, bare) == "Me at the zoo.mp4")
        let garbled = VideoDetails(id: "jNQXAC9IVRw", title: "Me at the zoo", uploadDate: "NA")
        #expect(path(.dateTitle, garbled) == "Me at the zoo.mp4")
    }

    func channelOrigin(_ name: String?) -> VideoOrigin {
        VideoOrigin(sourceKind: .channel, videoID: zoo.id, channelName: name, playlistIndex: 1, playlistCount: 1)
    }

    func playlistOrigin(_ title: String?, index: Int?, count: Int?) -> VideoOrigin {
        VideoOrigin(
            sourceKind: .playlist, videoID: zoo.id, channelName: "Some Owner",
            playlistTitle: title, playlistIndex: index, playlistCount: count
        )
    }

    @Test func channelSourceGoesInAChannelFolder() {
        #expect(path(.title, zoo, origin: channelOrigin("jawed")) == "jawed/Me at the zoo.mp4")
        #expect(path(.dateTitle, zoo, origin: channelOrigin("jawed")) == "jawed/2005-04-24 - Me at the zoo.mp4")
    }

    @Test func playlistSourceGoesInAPlaylistFolderWithAZeroPaddedIndex() {
        let origin = playlistOrigin("Zoo Trips", index: 3, count: 12)
        #expect(path(.title, zoo, origin: origin) == "Zoo Trips/03 - Me at the zoo.mp4")
        #expect(path(.channelTitle, zoo, origin: origin) == "Zoo Trips/03 - jawed - Me at the zoo.mp4")
    }

    @Test func playlistIndexIsPaddedToTheWidthOfTheCount() {
        #expect(path(.title, zoo, origin: playlistOrigin("Big", index: 7, count: 250)) == "Big/007 - Me at the zoo.mp4")
        #expect(path(.title, zoo, origin: playlistOrigin("Big", index: 7, count: nil)) == "Big/07 - Me at the zoo.mp4")
        #expect(path(.title, zoo, origin: playlistOrigin("Big", index: nil, count: 3)) == "Big/Me at the zoo.mp4")
    }

    @Test func aSourceWithoutANameStillGetsItsOwnFolder() {
        #expect(path(.title, zoo, origin: channelOrigin(nil)) == "Untitled channel/Me at the zoo.mp4")
        #expect(path(.title, zoo, origin: playlistOrigin("🎵", index: 1, count: 2)) == "Untitled playlist/01 - Me at the zoo.mp4")
    }

    func titled(_ title: String, channel: String? = nil) -> VideoDetails {
        VideoDetails(id: "dQw4w9WgXcQ", title: title, channel: channel, uploadDate: "20091025")
    }

    @Test func emojiAreStripped() {
        #expect(path(.title, titled("🔥 Best Of 2024 🎉🎉")) == "Best Of 2024.mp4")
        #expect(path(.title, titled("Family 👨‍👩‍👧 trip 🇫🇷 ❤️ 1️⃣")) == "Family trip.mp4")
        #expect(path(.title, titled("I ♥ NY 🏳️‍🌈")) == "I ♥ NY.mp4")
    }

    @Test func otherUnicodeIsKept() {
        #expect(path(.title, titled("Café à Zürich - 東京 - ©2024 - № 5 - 3 > 2")) == "Café à Zürich - 東京 - ©2024 - № 5 - 3 > 2.mp4")
    }

    @Test func slashesAndColonsAreReplaced() {
        #expect(path(.title, titled("AC/DC: Live at 12:30")) == "AC-DC - Live at 12-30.mp4")
        #expect(path(.channelTitle, titled("Song", channel: "Me/You")) == "Me-You - Song.mp4")
    }

    @Test func controlCharactersLeadingDotsAndExtraSpacesAreCleaned() {
        #expect(path(.title, titled("..hidden\tname\n  here  ")) == "hidden name here.mp4")
    }

    @Test func folderNamesGetTheSameCleanup() {
        #expect(path(.title, zoo, origin: channelOrigin("🎸 Rock/Roll: Channel")) == "Rock-Roll - Channel/Me at the zoo.mp4")
    }

    @Test func aTitleLeftEmptyFallsBackToTheVideoID() {
        #expect(path(.title, titled("🎉🎉🎉")) == "dQw4w9WgXcQ.mp4")
        #expect(path(.title, titled("")) == "dQw4w9WgXcQ.mp4")
        #expect(path(.channelTitle, titled("🎉", channel: "Rick")) == "Rick - dQw4w9WgXcQ.mp4")
        #expect(path(.title, titled("🎉"), origin: playlistOrigin("P", index: 1, count: 1)) == "P/01 - dQw4w9WgXcQ.mp4")
    }

    @Test func idSuffixGoesBeforeTheExtension() {
        #expect(path(.title, zoo, idSuffix: true) == "Me at the zoo [jNQXAC9IVRw].mp4")
        #expect(
            path(.title, zoo, origin: playlistOrigin("Zoo", index: 2, count: 9), ext: "mp3", idSuffix: true)
                == "Zoo/02 - Me at the zoo [jNQXAC9IVRw].mp3"
        )
    }

    @Test func longNamesAreTrimmedUnderTheFilesystemLimitKeepingPrefixSuffixAndExtension() {
        let long = String(repeating: "Ä", count: 300)  // 2 bytes each in UTF-8, 3 decomposed
        let result = path(.title, titled(long), origin: playlistOrigin(long, index: 4, count: 10), idSuffix: true)
        let parts = result.split(separator: "/").map(String.init)
        #expect(parts.count == 2)
        for part in parts {
            #expect(part.decomposedStringWithCanonicalMapping.utf8.count <= 255)
        }
        #expect(parts[0].hasPrefix("ÄÄÄ"))
        #expect(parts[1].hasPrefix("04 - ÄÄÄ"))
        #expect(parts[1].hasSuffix("Ä [dQw4w9WgXcQ].mp4"))
    }

    @Test func trimmingNeverSplitsACharacterOrLeavesTrailingSpace() {
        let title = String(repeating: "ab ", count: 120)
        let file = path(.title, titled(title))
        #expect(file.utf8.count <= 255)
        #expect(!file.contains(" .mp4"))
    }

    @Test func eachPresetShowsAnExampleNameInTheChosenFormat() {
        #expect(NamingPattern.title.example(format: .video) == "My Video.mp4")
        #expect(NamingPattern.channelTitle.example(format: .video) == "Some Channel - My Video.mp4")
        #expect(NamingPattern.dateTitle.example(format: .mp3) == "2026-10-12 - My Video.mp3")
    }

    @Test func mp3KeepsTheSameNameWithItsOwnExtension() {
        #expect(path(.title, zoo, ext: "mp3") == "Me at the zoo.mp3")
    }
}
