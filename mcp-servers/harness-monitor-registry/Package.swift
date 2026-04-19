// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HarnessMonitorRegistry",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "HarnessMonitorRegistry",
      targets: ["HarnessMonitorRegistry"]
    ),
    .executable(
      name: "harness-monitor-registry-host",
      targets: ["HarnessMonitorRegistryHost"]
    ),
    .executable(
      name: "harness-monitor-input",
      targets: ["HarnessMonitorInputTool"]
    )
  ],
  targets: [
    .target(
      name: "HarnessMonitorRegistry",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
        .enableExperimentalFeature("StrictConcurrency"),
        .unsafeFlags(["-strict-concurrency=complete"])
      ]
    ),
    .executableTarget(
      name: "HarnessMonitorRegistryHost",
      dependencies: ["HarnessMonitorRegistry"],
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
        .unsafeFlags(["-strict-concurrency=complete"])
      ]
    ),
    .executableTarget(
      name: "HarnessMonitorInputTool",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
        .unsafeFlags(["-strict-concurrency=complete"])
      ]
    ),
    .testTarget(
      name: "HarnessMonitorRegistryTests",
      dependencies: ["HarnessMonitorRegistry"],
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
        .unsafeFlags(["-strict-concurrency=complete"])
      ]
    )
  ]
)
