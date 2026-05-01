// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BaseStudio",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BaseStudio", targets: ["BaseStudioApp"]),
        .library(name: "BaseStudioCore", targets: ["BaseStudioCore"]),
        .library(name: "BaseStudioRecording", targets: ["BaseStudioRecording"]),
        .library(name: "BaseStudioRender", targets: ["BaseStudioRender"]),
        .library(name: "BaseStudioPlayback", targets: ["BaseStudioPlayback"]),
    ],
    targets: [
        .target(name: "BaseStudioCore"),
        .target(
            name: "BaseStudioRecording",
            dependencies: ["BaseStudioCore"]
        ),
        .target(
            name: "BaseStudioRender",
            dependencies: ["BaseStudioCore"]
        ),
        .target(
            name: "BaseStudioPlayback",
            dependencies: ["BaseStudioCore"]
        ),
        .executableTarget(
            name: "BaseStudioApp",
            dependencies: [
                "BaseStudioCore",
                "BaseStudioRecording",
                "BaseStudioRender",
                "BaseStudioPlayback",
            ],
            linkerSettings: [
                // Embed Info.plist in __TEXT,__info_plist so AVCaptureSession
                // (camera/mic) can read NSCameraUsageDescription / NSMicrophoneUsageDescription.
                // Without this, the app crashes the moment a capture session starts.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "BaseStudioCoreTests",
            dependencies: ["BaseStudioCore"]
        ),
        .testTarget(
            name: "BaseStudioRenderTests",
            dependencies: ["BaseStudioCore", "BaseStudioRender"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
