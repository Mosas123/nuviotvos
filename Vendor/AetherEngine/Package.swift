// swift-tools-version: 6.0
// Nuvio pin of AetherEngine 7.33.2 with local FFmpegBuild integrations.

import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v16),
        .tvOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AetherEngine",
            type: .static,
            targets: ["AetherEngine"]
        ),
        .library(
            name: "AetherEngineSMB",
            targets: ["AetherEngineSMB"]
        ),
    ],
    dependencies: [
        .package(path: "../FFmpegBuild"),
        .package(url: "https://github.com/kishikawakatsumi/SMBClient", .upToNextMinor(from: "0.3.1")),
        .package(url: "https://github.com/superuser404notfound/LibDovi", .upToNextMinor(from: "2.1.0")),
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "Dovi", package: "LibDovi"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .target(
            name: "AetherEngineSMB",
            dependencies: [
                "AetherEngine",
                .product(name: "SMBClient", package: "SMBClient"),
            ],
            path: "Sources/AetherEngineSMB"
        ),
        .executableTarget(
            name: "aetherctl",
            dependencies: ["AetherEngine", "AetherEngineSMB"],
            path: "Sources/aetherctl"
        ),
        .target(
            name: "ExampleSources",
            dependencies: ["AetherEngine"],
            path: "Examples",
            exclude: ["README.md", "DemoPlayerMac"]
        ),
        .testTarget(
            name: "AetherEngineTests",
            dependencies: ["AetherEngine"],
            path: "Tests/AetherEngineTests"
        ),
        .testTarget(
            name: "AetherEngineSMBTests",
            dependencies: ["AetherEngineSMB"],
            path: "Tests/AetherEngineSMBTests"
        ),
    ]
)
