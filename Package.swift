// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Particularity",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Particularity",
            path: "Sources/Physics_Sim",
            resources: [
                .process("Shaders"),
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(
            name: "ParticularityTests",
            dependencies: ["Particularity"]
        ),
    ]
)
