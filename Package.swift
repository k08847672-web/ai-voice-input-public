// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInputCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VoiceInputCore", targets: ["VoiceInputCore"]),
        .library(name: "VoiceInputMobileShared", targets: ["VoiceInputMobileShared"])
    ],
    targets: [
        .target(
            name: "VoiceInputCore",
            path: "Sources/VoiceInputCore"
        ),
        .target(
            name: "VoiceInputMobileShared",
            path: "Sources/VoiceInputMobileShared"
        ),
        .testTarget(
            name: "VoiceInputCoreTests",
            dependencies: ["VoiceInputCore"],
            path: "Tests/VoiceInputCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VoiceInputMobileSharedTests",
            dependencies: ["VoiceInputMobileShared"],
            path: "Tests/VoiceInputMobileSharedTests"
        )
    ]
)
