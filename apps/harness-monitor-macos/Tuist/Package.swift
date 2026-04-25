// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [
        "Lottie": .framework,
        "Textual": .framework
    ],
    baseSettings: .settings(
        configurations: [
            .debug(name: "Debug"),
            .debug(name: "Preview"),
            .release(name: "Release")
        ]
    )
)
#endif

let package = Package(
    name: "HarnessMonitorDeps",
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-ios", exact: "4.6.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift", exact: "2.3.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core", exact: "2.4.1"),
        .package(url: "https://github.com/grpc/grpc-swift", exact: "1.27.0"),
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.3.1"),
        .package(path: "../../../mcp-servers/harness-monitor-registry")
    ]
)
