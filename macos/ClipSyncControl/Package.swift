// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipSyncControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipSyncControl", targets: ["ClipSyncControl"]),
    ],
    targets: [
        .executableTarget(name: "ClipSyncControl"),
        .testTarget(name: "ClipSyncControlTests", dependencies: ["ClipSyncControl"]),
    ]
)
