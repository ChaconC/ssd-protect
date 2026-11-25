// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SSDProtect",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DriveArbitration"),
        .executableTarget(name: "SSDProtect", dependencies: ["DriveArbitration"]),
        .testTarget(name: "SettingsTests", dependencies: ["SSDProtect"]),
        .testTarget(name: "DriveArbitrationTests", dependencies: ["DriveArbitration"])
    ]
)
