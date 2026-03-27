// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClaudeMonitor", targets: ["ClaudeMonitor"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClaudeMonitor",
            dependencies: [],
            path: "ClaudeMonitor"
        )
    ]
)
