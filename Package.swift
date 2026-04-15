// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "VoiceboxKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "VoiceboxKit",
            targets: ["VoiceboxKit"]
        )
    ],
    targets: [
        .target(
            name: "VoiceboxKit",
            path: "Sources/VoiceboxKit"
        ),
        .testTarget(
            name: "VoiceboxKitTests",
            dependencies: ["VoiceboxKit"],
            path: "Tests/VoiceboxKitTests"
        )
    ]
)
