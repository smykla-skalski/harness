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
