import ProjectDescription

public enum BuildSettings {
    public static let base: SettingsDictionary = [
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_TREAT_WARNINGS_AS_ERRORS": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
        "CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION": "YES",
        "CODE_SIGNING_ALLOWED": "YES",
        "COMPILATION_CACHE_ENABLE_CACHING": "YES",
        "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
        "CURRENT_PROJECT_VERSION": "30.14.5", // VERSION_MARKER_CURRENT
        "DEVELOPMENT_TEAM": "Q498EB36N4",
        "DEAD_CODE_STRIPPING": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "26.0",
        "MTL_FAST_MATH": "YES",
        "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_ENABLE_EAGER_LINKING": "YES",
        "SWIFT_ENABLE_PREFIX_MAPPING": "YES",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
        "SWIFT_VERSION": "6.2",
        "HARNESS_MONITOR_BUILD_GIT_COMMIT": "local-dev",
        "HARNESS_MONITOR_BUILD_GIT_DIRTY": "false",
        "HARNESS_MONITOR_BUILD_WORKSPACE_FINGERPRINT": "local-dev",
        "MARKETING_VERSION": "30.14.5" // VERSION_MARKER_MARKETING
    ]

    public static let previewOverrides: SettingsDictionary = [
        // CAS compilation cache stable keys depend on SWIFT_ENABLE_PREFIX_MAPPING=YES.
        // Preview dylib builds need prefix mapping off, so caching must go off too,
        // otherwise XOJIT's preview-thunk + preview-thunk-launch resolve to stale CAS
        // objects with duplicate symbols and the preview agent process is removed.
        "COMPILATION_CACHE_ENABLE_CACHING": "NO",
        "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "NO",
        "COMPILER_INDEX_STORE_ENABLE": "NO",
        // Preview agent attaches to the host app via task port and loads
        // dynamically generated preview-thunk dylibs. Hardened runtime blocks
        // both, so the app launches but is killed before SwiftUI handshake.
        "ENABLE_HARDENED_RUNTIME": "NO",
        "ENABLE_TESTABILITY": "NO",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ENABLE_EAGER_LINKING": "NO",
        // Preview dylib builds choke on prefix-mapped SDK overlay paths like `^sdk/...`.
        "SWIFT_ENABLE_PREFIX_MAPPING": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "NO"
    ]

    public static let debugOverrides: SettingsDictionary = [
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE"
    ]

    public static let configurations: [Configuration] = [
        .debug(name: "Debug", settings: debugOverrides),
        .debug(name: "Preview", settings: previewOverrides),
        .release(name: "Release")
    ]

    public static func projectSettings() -> Settings {
        .settings(base: base, configurations: configurations)
    }

    public static func frameworkSettings(
        bundleId: String,
        previewIndexOff: Bool = true,
        extraBase: SettingsDictionary = [:]
    ) -> Settings {
        var preview: SettingsDictionary = [:]
        if previewIndexOff {
            preview["COMPILER_INDEX_STORE_ENABLE"] = "NO"
            preview["ONLY_ACTIVE_ARCH"] = "YES"
            preview["SWIFT_ENABLE_EAGER_LINKING"] = "NO"
        }
        preview["SWIFT_ENABLE_PREFIX_MAPPING"] = "NO"
        var base: SettingsDictionary = [
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGNING_ALLOWED": "YES",
            "ENABLE_MODULE_VERIFIER": "YES",
            "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
            "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu17 gnu++20",
            "PRODUCT_BUNDLE_IDENTIFIER": .string(bundleId)
        ]
        for (key, value) in extraBase {
            base[key] = value
        }
        return .settings(
            base: base,
            configurations: [
                .debug(name: "Debug"),
                .debug(name: "Preview", settings: preview),
                .release(name: "Release")
            ]
        )
    }
}
