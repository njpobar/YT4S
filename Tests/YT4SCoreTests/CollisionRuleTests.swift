import Foundation
import Testing
@testable import YT4SCore

/// Final names are predicted before download: only a clash with a different video adds ` [<id>]`.
@Suite struct CollisionRuleTests {
    let plan = NamePlan(folders: ["Zoo"], indexPrefix: "01", stem: "Me at the zoo")

    func resolve(_ occupants: [String: FileOccupant], ext: String = "mp4", downloadAgain: Bool = false) -> String {
        plan.resolvedPath(videoID: "jNQXAC9IVRw", fileExtension: ext, downloadAgain: downloadAgain) { occupants[$0] ?? .free }
    }

    @Test func aFreeNameHasNoID() {
        #expect(resolve([:]) == "Zoo/01 - Me at the zoo.mp4")
    }

    /// The caller finds that file already there and marks the item Already downloaded.
    @Test func theSameVideoInTheSameFormatKeepsItsName() {
        #expect(resolve(["Zoo/01 - Me at the zoo.mp4": .sameVideo]) == "Zoo/01 - Me at the zoo.mp4")
    }

    @Test func aDifferentVideoWithThatNameGivesTheNewcomerItsID() {
        #expect(resolve(["Zoo/01 - Me at the zoo.mp4": .otherVideo]) == "Zoo/01 - Me at the zoo [jNQXAC9IVRw].mp4")
    }

    @Test func theOtherFormatDoesNotClash() {
        #expect(resolve(["Zoo/01 - Me at the zoo.mp4": .otherVideo], ext: "mp3") == "Zoo/01 - Me at the zoo.mp3")
    }

    @Test func downloadAgainNeverReusesTheSameVideosNameAndGetsTheID() {
        #expect(resolve(["Zoo/01 - Me at the zoo.mp4": .sameVideo], downloadAgain: true) == "Zoo/01 - Me at the zoo [jNQXAC9IVRw].mp4")
    }

    @Test func downloadAgainWhenTheIDNameIsTakenTooCountsUp() {
        let occupants: [String: FileOccupant] = [
            "Zoo/01 - Me at the zoo.mp4": .sameVideo,
            "Zoo/01 - Me at the zoo [jNQXAC9IVRw].mp4": .sameVideo,
        ]
        #expect(resolve(occupants, downloadAgain: true) == "Zoo/01 - Me at the zoo [jNQXAC9IVRw] 2.mp4")
    }

    @Test func aForeignFileAlreadyCarryingTheIDNameIsNeverTaken() {
        let occupants: [String: FileOccupant] = [
            "Zoo/01 - Me at the zoo.mp4": .otherVideo,
            "Zoo/01 - Me at the zoo [jNQXAC9IVRw].mp4": .otherVideo,
            "Zoo/01 - Me at the zoo [jNQXAC9IVRw] 2.mp4": .otherVideo,
        ]
        #expect(resolve(occupants) == "Zoo/01 - Me at the zoo [jNQXAC9IVRw] 3.mp4")
    }
}
