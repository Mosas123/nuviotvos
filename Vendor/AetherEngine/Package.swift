// swift-tools-version: 6.1
// Nuvio pin of AetherEngine 7.39.0 with local FFmpegBuild integrations.

import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
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
    // Four optional components, all off by default. A host that wants one enables its trait
    // (`.package(url:..., traits: [...])`, or the package's traits in Xcode); without it the code is not
    // compiled and the library behind it is not linked. These components may be subject to third-party
    // patent licensing; an integrator that enables one is responsible for its own licensing. Off, the
    // matching LoadOptions are accepted and change nothing: object audio keeps the channel bridge, a
    // Profile 7 source keeps the native route, and a Dolby Vision Profile 5 / 10.0 source yields no
    // scrub still or held picture. LibDovi, FFmpeg and everything else are unaffected.
    traits: [
        .trait(
            name: "TrueHDObjectAudio",
            description: "Link LibTrueHD and the object renderer, so objectAudioRendering can render TrueHD Atmos objects to APAC."
        ),
        .trait(
            name: "DTSXObjectAudio",
            description: "Link LibDTSX and the object renderer, so objectAudioRendering can render DTS:X heights and objects to APAC."
        ),
        .trait(
            name: "DualLayerDolbyVision",
            description: "Compile the Dolby Vision Profile 7 FEL dual-layer composer, so preferDualLayerDolbyVision can take that route."
        ),
        .trait(
            name: "DolbyVisionStillReshaping",
            description: "Compile the CPU reshaping that turns a Dolby Vision Profile 5 / 10.0 frame into a still (scrub thumbnails, I-frame stills, held pictures)."
        ),
        .default(enabledTraits: [
            "TrueHDObjectAudio",
            "DTSXObjectAudio",
            "DualLayerDolbyVision",
            "DolbyVisionStillReshaping",
        ]),
    ],
    dependencies: [
        .package(path: "../FFmpegBuild"),
        .package(url: "https://github.com/kishikawakatsumi/SMBClient", .upToNextMinor(from: "0.3.1")),
        .package(url: "https://github.com/superuser404notfound/LibDovi", .upToNextMinor(from: "2.1.0")),
        .package(url: "https://github.com/superuser404notfound/LibTrueHD", .upToNextMinor(from: "2.3.1")),
        .package(url: "https://github.com/superuser404notfound/LibDTSX", .upToNextMinor(from: "2.0.0")),
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "Dovi", package: "LibDovi"),
                .product(name: "TrueHD", package: "LibTrueHD", condition: .when(traits: ["TrueHDObjectAudio"])),
                .product(name: "DTSX", package: "LibDTSX", condition: .when(traits: ["DTSXObjectAudio"])),
            ],
            resources: [.copy("Resources/silent-atmos.mp4")],
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
