import Foundation
import Testing
@testable import YT4SCore

@Suite struct InstallLocationTests {
    @Test func runsFromApplications() {
        #expect(InstallLocation(bundlePath: "/Applications/YT4S.app").mustMove == false)
        #expect(InstallLocation(bundlePath: "/Applications/YT4S.app/").mustMove == false)
    }

    @Test(arguments: [
        "/Users/sarah/Downloads/YT4S.app",
        "/Volumes/YT4S 1.0.0/YT4S.app",
        "/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/YT4S.app",
        "/Users/sarah/Applications/YT4S.app",
        "/Applications/Utilities/YT4S.app",
        "/Applications/../Users/sarah/YT4S.app",
        "/ApplicationsOld/YT4S.app",
    ])
    func asksToBeMovedFromAnywhereElse(path: String) {
        #expect(InstallLocation(bundlePath: path).mustMove)
    }

    @Test func aBareExecutableIsADevelopmentRunAndIsLeftAlone() {
        // `swift run` launches the binary straight from .build, not from an .app bundle.
        #expect(InstallLocation(bundlePath: "/Users/nick/YT4S/.build/out/Products/Debug").mustMove == false)
    }

    @Test func theOverrideLetsADevelopmentBuildRunFromBuildFolder() {
        let location = InstallLocation(bundlePath: "/Users/nick/YT4S/build/YT4S.app", allowAnyLocation: true)
        #expect(location.mustMove == false)
    }
}
