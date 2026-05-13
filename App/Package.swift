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
            // Exclude the .iconset build-artefact folder — generate-
            // icon.swift rasterises Resources/AppIcon-Master.pdf into
            // ten PNGs there before iconutil rolls them up into
            // AppIcon.icns. SwiftPM resource processing would
            // otherwise see those PNGs as bundle resources, but
            // they're intermediate artefacts; the .icns + master
            // PDF are what we actually ship.
            exclude: [
                "Resources/AppIcon.iconset",
                "Resources/AppIcon-Master.pdf",
            ],
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
