// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessMonitorPerf",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "harness-monitor-perf", targets: ["harness-monitor-perf"]),
        .library(name: "HarnessMonitorPerfCore", targets: ["HarnessMonitorPerfCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.1"),
    ],
    targets: [
        .executableTarget(
            name: "harness-monitor-perf",
            dependencies: [
                "HarnessMonitorPerfCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "HarnessMonitorPerfCore"
        ),
        .testTarget(
            name: "HarnessMonitorPerfCoreTests",
            dependencies: ["HarnessMonitorPerfCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
