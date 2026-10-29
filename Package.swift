// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v13)],
    targets: [
        // Embeds an Info.plist into the executable (see Sources/NotchIslandInfoPlist/info.c).
        .target(
            name: "NotchIslandInfoPlist",
            path: "Sources/NotchIslandInfoPlist"
        ),
        .executableTarget(
            name: "NotchIsland",
            dependencies: ["NotchIslandInfoPlist"],
            path: "Sources/NotchIsland",
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
