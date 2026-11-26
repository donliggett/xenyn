// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Xenyn",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Xenyn",
            path: "Sources/Xenyn",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreAudioKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
