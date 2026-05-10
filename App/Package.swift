// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LociiGhost",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LociiGhostCore",
            targets: ["LociiGhostCore"]
        ),
        .executable(
            name: "lociighostctl",
            targets: ["lociighostctl"]
        ),
        .executable(
            name: "LociiGhost",
            targets: ["LociiGhost"]
        ),
    ],
    targets: [
        .target(
            name: "LociiGhostCore",
            path: "Sources/LociiGhostCore"
        ),
        .executableTarget(
            name: "lociighostctl",
            dependencies: ["LociiGhostCore"],
            path: "Sources/lociighostctl"
        ),
        .executableTarget(
            name: "LociiGhost",
            dependencies: ["LociiGhostCore"],
            path: "Sources/LociiGhost",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "LociiGhostCoreTests",
            dependencies: ["LociiGhostCore"],
            path: "Tests/LociiGhostCoreTests"
        ),
    ]
)
