// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PingWatcher",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PingWatcher",
            path: "Sources/PingWatcher"
        )
    ]
)
