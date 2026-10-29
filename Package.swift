// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Command Line Tools workaround: with only CLT installed (no Xcode), SwiftPM's default
// swiftbuild backend does not pass the swift-testing macro plugin to the compiler, so
// `@Test` / `#expect` fail with "plugin for module 'TestingMacros' not found".
// When the active developer dir is CLT, point the test target at the plugin explicitly.
// Under Xcode (CI) this is a no-op.
let commandLineTools = "/Library/Developer/CommandLineTools"
let cltTestingPlugins = commandLineTools + "/usr/lib/swift/host/plugins/testing"
let activeDeveloperDir = Context.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
let testSwiftSettings: [SwiftSetting] =
    activeDeveloperDir == commandLineTools && FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])]
    : []

let package = Package(
    name: "YT4S",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YT4S", targets: ["YT4S"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // SwiftUI app shell. Kept thin: logic lives in YT4SCore so it is testable.
        .executableTarget(
            name: "YT4S",
            dependencies: [
                "YT4SCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // Sparkle.framework is embedded at YT4S.app/Contents/Frameworks by scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .target(name: "YT4SCore"),
        .testTarget(
            name: "YT4SCoreTests",
            dependencies: ["YT4SCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: testSwiftSettings
        ),
    ]
)
