// swift-tools-version: 6.0
// RobogearsCore holds every rule of the app that doesn't need a window:
// link and tracklist parsing, matching, TIDAL and Spotify access, the library
// index, the download pipeline and the updater. The app target only draws.
import PackageDescription

let package = Package(
    name: "RobogearsCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RobogearsCore", targets: ["RobogearsCore"]),
    ],
    targets: [
        .target(
            name: "RobogearsCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RobogearsCoreTests",
            dependencies: ["RobogearsCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
