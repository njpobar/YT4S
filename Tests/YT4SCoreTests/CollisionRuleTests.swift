import Foundation
import Testing
@testable import YT4SCore

/// Final names are predicted before download: only a clash with a different video adds ` [<id>]`.
@Suite struct CollisionRuleTests {
    let plan = NamePlan(folders: ["Zoo"], indexPrefix: "01", stem: "Me at the zoo")

    func resolve(_ occupants: [String: FileOccupant], ext: String = "mp4") -> String {
        plan.resolvedPath(videoID: "jNQXAC9IVRw", fileExtension: ext) { occupants[$0] ?? .free }
    }

    @Test func aFreeNameHasNoID() {
        #expect(resolve([:]) == "Zoo/01 - Me at the zoo.mp4")
    }

    @Test func theSameVideoKeepsItsName() {
        #expect(resolve(["Zoo/01 - Me at the zoo.mp4": .sameVideo]) == "Zoo/01 - Me at the zoo.mp4")
    }

    @Test func aDifferentVideoWithThatNameGivesTheNewcomerItsID() {
        #expect(resolve(["Zoo/01 - Me at the zoo.mp4": .otherVideo]) == "Zoo/01 - Me at the zoo [jNQXAC9IVRw].mp4")
    }

    @Test func theOtherFormatDoesNotClash() {
        #expect(resolve(["Zoo/01 - Me at the zoo.mp4": .otherVideo], ext: "mp3") == "Zoo/01 - Me at the zoo.mp3")
    }
}
