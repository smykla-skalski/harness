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
        base: [
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
            "CLANG_ENABLE_OBJC_WEAK": "YES",
            "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
            "COMPILATION_CACHE_ENABLE_CACHING": "YES",
            "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
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
    )
)
#endif

let package = Package(
    name: "HarnessMonitorDeps",
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-ios", exact: "4.6.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift", exact: "2.3.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core", exact: "2.4.1"),
        .package(url: "https://github.com/grpc/grpc-swift", exact: "1.27.5"),
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.3.1"),
        .package(path: "../../../mcp-servers/harness-monitor-registry")
    ]
)
