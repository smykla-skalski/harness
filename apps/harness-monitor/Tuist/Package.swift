// swift-tools-version: 6.0
import Foundation
import PackageDescription

#if TUIST
import ProjectDescription

private let compilationCacheDiagnosticRemarksEnabled: Bool = {
    guard
        let raw = ProcessInfo.processInfo.environment[
            "HARNESS_MONITOR_COMPILATION_CACHE_DIAGNOSTICS"
        ]?.lowercased()
    else {
        return false
    }
    return ["1", "true", "yes", "on"].contains(raw)
}()

let packageSettings = PackageSettings(
    baseSettings: .settings(
        base: [
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
            "CLANG_ENABLE_OBJC_WEAK": "YES",
            "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
            "COMPILATION_CACHE_ENABLE_CACHING": "YES",
            "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": .string(
                compilationCacheDiagnosticRemarksEnabled ? "YES" : "NO"
            ),
            "ENABLE_MODULE_VERIFIER": "YES",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            "GCC_NO_COMMON_BLOCKS": "YES",
            "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
            "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
            "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu17 gnu++20",
            "MTL_FAST_MATH": "YES",
            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
            "SWIFT_ENABLE_PREFIX_MAPPING": "YES"
        ],
        configurations: [
            .debug(name: "Debug", settings: [
                "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE"
            ]),
            .debug(name: "Preview", settings: [
                "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
                "SWIFT_ENABLE_PREFIX_MAPPING": "NO"
            ]),
            .release(name: "Release")
        ]
    ),
    targetSettings: [
        "ElkSwift": .settings(
            configurations: [
                .debug(name: "Debug", settings: [
                    "SWIFT_COMPILATION_MODE": "wholemodule",
                    "SWIFT_OPTIMIZATION_LEVEL": "-O"
                ]),
                .debug(name: "Preview", settings: [
                    "SWIFT_COMPILATION_MODE": "wholemodule",
                    "SWIFT_OPTIMIZATION_LEVEL": "-O"
                ])
            ]
        )
    ]
)
#endif

let package = Package(
    name: "HarnessMonitorDeps",
    dependencies: [
        .package(url: "https://github.com/krisk/fuse-swift.git", exact: "2.0.0-rc.1"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift", exact: "2.3.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core", exact: "2.5.1"),
        .package(url: "https://github.com/grpc/grpc-swift", exact: "1.27.0"),
        .package(url: "https://github.com/lukilabs/elk-swift.git", exact: "1.0.2"),
        .package(path: "../../../mcp-servers/harness-monitor-registry")
    ]
)
