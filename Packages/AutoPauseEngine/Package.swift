// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoPauseEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AutoPauseEngine", targets: ["AutoPauseEngine"])
    ],
    targets: [
        .target(
            name: "AutoPauseEngine",
            path: "Sources/AutoPauseEngine"
        ),
        .testTarget(
            name: "AutoPauseEngineTests",
            dependencies: ["AutoPauseEngine"],
            path: "Tests/AutoPauseEngineTests"
        ),
    ]
)
