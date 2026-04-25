import ProjectDescription

public enum BuildSettings {
    public static let base: SettingsDictionary = [
        "CLANG_TREAT_WARNINGS_AS_ERRORS": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION": "YES",
        "CODE_SIGNING_ALLOWED": "YES",
        "CURRENT_PROJECT_VERSION": "30.3.0", // VERSION_MARKER_CURRENT
        "DEAD_CODE_STRIPPING": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "26.0",
        "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_ENABLE_EAGER_LINKING": "YES",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
        "SWIFT_VERSION": "6.2",
        "HARNESS_MONITOR_APP_BUNDLE_ID": "io.harnessmonitor.app",
        "HARNESS_MONITOR_BUILD_GIT_COMMIT": "local-dev",
        "HARNESS_MONITOR_BUILD_GIT_DIRTY": "false",
        "HARNESS_MONITOR_BUILD_WORKSPACE_FINGERPRINT": "local-dev",
        "MARKETING_VERSION": "30.3.0" // VERSION_MARKER_MARKETING
    ]

    public static let previewOverrides: SettingsDictionary = [
        "COMPILER_INDEX_STORE_ENABLE": "NO",
        "ENABLE_TESTABILITY": "NO",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ENABLE_EAGER_LINKING": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "NO"
    ]

    public static let configurations: [Configuration] = [
        .debug(name: "Debug"),
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
        var preview: SettingsDictionary = [
            "ENABLE_MODULE_VERIFIER": "NO"
        ]
        if previewIndexOff {
            preview["COMPILER_INDEX_STORE_ENABLE"] = "NO"
            preview["ONLY_ACTIVE_ARCH"] = "YES"
            preview["SWIFT_ENABLE_EAGER_LINKING"] = "NO"
        }
        var base: SettingsDictionary = [
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGNING_ALLOWED": "YES",
            "DEVELOPMENT_TEAM": "Q498EB36N4",
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
