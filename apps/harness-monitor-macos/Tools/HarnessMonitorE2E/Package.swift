// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessMonitorE2E",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "harness-monitor-e2e", targets: ["harness-monitor-e2e"]),
        .library(name: "HarnessMonitorE2ECore", targets: ["HarnessMonitorE2ECore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "harness-monitor-e2e",
            dependencies: [
                "HarnessMonitorE2ECore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "HarnessMonitorE2ECore"
        ),
        .testTarget(
            name: "HarnessMonitorE2ECoreTests",
            dependencies: ["HarnessMonitorE2ECore"]
        ),
    ]
)
