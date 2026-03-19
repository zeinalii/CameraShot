// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CameraShot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CameraShot",
            path: "Sources/CameraShot",
            resources: [.process("Resources")]
        )
    ]
)
