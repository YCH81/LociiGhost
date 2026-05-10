// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocWarpMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LocWarpCore",
            targets: ["LocWarpCore"]
        ),
        .executable(
            name: "locwarpctl",
            targets: ["locwarpctl"]
        ),
        .executable(
            name: "LocWarpMac",
            targets: ["LocWarpMac"]
        ),
    ],
    targets: [
        .target(
            name: "LocWarpCore",
            path: "Sources/LocWarpCore"
        ),
        .executableTarget(
            name: "locwarpctl",
            dependencies: ["LocWarpCore"],
            path: "Sources/locwarpctl"
        ),
        .executableTarget(
            name: "LocWarpMac",
            dependencies: ["LocWarpCore"],
            path: "Sources/LocWarpMac",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "LocWarpCoreTests",
            dependencies: ["LocWarpCore"],
            path: "Tests/LocWarpCoreTests"
        ),
    ]
)
