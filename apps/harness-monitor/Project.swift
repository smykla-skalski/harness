import ProjectDescription
import ProjectDescriptionHelpers

private let macOSDestinations: Destinations = [.mac]
private let macOSDeploymentTargets: DeploymentTargets = .macOS("26.0")
private let iOSDestinations: Destinations = [.iPhone, .iPad]
private let iOSDeploymentTargets: DeploymentTargets = .iOS("26.0")
private let applePlatformDestinations: Destinations = [.mac, .iPhone, .iPad, .appleWatch]
private let applePlatformDeploymentTargets: DeploymentTargets = .multiplatform(
    iOS: "26.0",
    macOS: "26.0",
    watchOS: "26.0"
)
private let watchDestinations: Destinations = [.appleWatch]
private let watchDeploymentTargets: DeploymentTargets = .watchOS("26.0")
private let xcodeVisibleAppEntitlementsPath: Path = "HarnessMonitorBase.entitlements"
private let xcodeVisibleExternalDaemonEntitlementsPath: Path =
    "HarnessMonitorExternalDaemon.entitlements"
private let generatedAppEntitlements: SettingValue =
    "$(PROJECT_TEMP_DIR)/GeneratedAppEntitlements/$(TARGET_NAME).codesign.entitlements"
private let isolatedAppEntitlementsPath: Path = "HarnessMonitorIsolated.entitlements"
private let isolatedAppBundleId: String = IsolatedAppIdentity.bundleId

private func staticFrameworkSettings(
    bundleId: String,
    moduleName: String,
    configurations: [Configuration] = [],
    extraBase: SettingsDictionary = [:]
) -> Settings {
    var base: SettingsDictionary = [
        "CODE_SIGN_IDENTITY": "",
        "CODE_SIGN_STYLE": "Automatic",
        "ENABLE_MODULE_VERIFIER": "YES",
        "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
        "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu17 gnu++20",
        "PRODUCT_BUNDLE_IDENTIFIER": .string(bundleId),
        "PRODUCT_MODULE_NAME": .string(moduleName),
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]
    for (key, value) in extraBase {
        base[key] = value
    }
    guard !configurations.isEmpty else {
        return .settings(base: base)
    }
    return .settings(base: base, configurations: configurations)
}

private let coreSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorCore/**/*.swift")
])

private let coreTarget: Target = .target(
    name: "HarnessMonitorCore",
    destinations: applePlatformDestinations,
    product: .staticFramework,
    bundleId: "io.harnessmonitor.core",
    deploymentTargets: applePlatformDeploymentTargets,
    sources: coreSources,
    resources: ["Sources/HarnessMonitorCore/Localizable.xcstrings"],
    settings: staticFrameworkSettings(
        bundleId: "io.harnessmonitor.core",
        moduleName: "HarnessMonitorCore"
    ),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:core"])
)

private let cryptoSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorCrypto/**/*.swift")
])

private let cryptoTarget: Target = .target(
    name: "HarnessMonitorCrypto",
    destinations: applePlatformDestinations,
    product: .staticFramework,
    bundleId: "io.harnessmonitor.crypto",
    deploymentTargets: applePlatformDeploymentTargets,
    sources: cryptoSources,
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .sdk(name: "CryptoKit", type: .framework),
        .sdk(name: "Security", type: .framework)
    ],
    settings: staticFrameworkSettings(
        bundleId: "io.harnessmonitor.crypto",
        moduleName: "HarnessMonitorCrypto"
    ),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:security"])
)

private let cloudMirrorSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorCloudMirror/**/*.swift")
])

private let cloudMirrorTarget: Target = .target(
    name: "HarnessMonitorCloudMirror",
    destinations: applePlatformDestinations,
    product: .staticFramework,
    bundleId: "io.harnessmonitor.cloudmirror",
    deploymentTargets: applePlatformDeploymentTargets,
    sources: cloudMirrorSources,
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .target(name: "HarnessMonitorCrypto"),
        .sdk(name: "CloudKit", type: .framework)
    ],
    settings: staticFrameworkSettings(
        bundleId: "io.harnessmonitor.cloudmirror",
        moduleName: "HarnessMonitorCloudMirror"
    ),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:integration"])
)

private let mirrorStoreSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorMirrorStore/**/*.swift")
])

private let mirrorStoreTarget: Target = .target(
    name: "HarnessMonitorMirrorStore",
    destinations: applePlatformDestinations,
    product: .staticFramework,
    bundleId: "io.harnessmonitor.mirrorstore",
    deploymentTargets: applePlatformDeploymentTargets,
    sources: mirrorStoreSources,
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .target(name: "HarnessMonitorCrypto"),
        .target(name: "HarnessMonitorCloudMirror"),
        .target(name: "HarnessMonitorCloudKit"),
        .sdk(name: "LocalAuthentication", type: .framework)
    ],
    settings: staticFrameworkSettings(
        bundleId: "io.harnessmonitor.mirrorstore",
        moduleName: "HarnessMonitorMirrorStore"
    ),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:integration"])
)

private let macRelaySources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorMacRelay/**/*.swift")
])

private let macRelayTarget: Target = .target(
    name: "HarnessMonitorMacRelay",
    destinations: macOSDestinations,
    product: .framework,
    bundleId: "io.harnessmonitor.mac-relay",
    deploymentTargets: macOSDeploymentTargets,
    sources: macRelaySources,
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .target(name: "HarnessMonitorCrypto"),
        .target(name: "HarnessMonitorCloudMirror"),
        .target(name: "HarnessMonitorKit"),
        .sdk(name: "Network", type: .framework)
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.mac-relay",
        "PRODUCT_MODULE_NAME": "HarnessMonitorMacRelay",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:relay"])
)

private let monitorAppSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitor/**/*.swift", excluding: [
        "Sources/HarnessMonitor/Features/**"
    ])
] + FeatureFlags.appAdditionalSourceGlobs(target: "HarnessMonitor"))

private let uiPreviewableSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorUIPreviewable/**/*.swift", excluding: [
        "Sources/HarnessMonitorUIPreviewable/Features/**",
        "Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas/**"
    ])
] + FeatureFlags.uiPreviewableAdditionalSourceGlobs())

private let kitSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorKit/**/*.swift", excluding: ["Sources/HarnessMonitorKit/Features/**"])
] + FeatureFlags.kitAdditionalSourceGlobs())

private let policyModelSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorPolicyModels/**/*.swift")
])

private let policyCanvasAlgorithmSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorPolicyCanvasAlgorithms/**/*.swift")
])

private let policyCanvasSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas/**/*.swift"),
    .glob("Sources/HarnessMonitorUIPreviewable/Theme/HarnessMonitorTheme.swift"),
    .glob("Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibility+Slug.swift"),
    .glob("Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibilityIDs+PolicyCanvas.swift"),
    .glob("Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibilityPolicyCanvas.swift"),
    .glob("Sources/HarnessMonitorUIPreviewable/Support/AutomationPolicyModels.swift"),
    .glob("Sources/HarnessMonitorUIPreviewable/Support/AutomationPolicySourceAppModels.swift"),
    .glob("Sources/HarnessMonitorUIPreviewable/Support/AutomationPolicyEvents.swift"),
    .glob("Sources/HarnessMonitorUIPreviewable/Support/AutomationPolicyDocument+Canvas.swift"),
    .glob("Sources/HarnessMonitorUIPreviewable/Support/AutomationPolicyDocument+Defaults.swift"),
    .glob("Sources/HarnessMonitorUIPreviewable/Support/AutomationPolicyExecutionPlanModels.swift"),
    .glob("Sources/HarnessMonitorPolicyCanvas/**/*.swift")
])

private let kitDependencies: [TargetDependency] = {
    var deps: [TargetDependency] = [
        .target(name: "HarnessMonitorPolicyModels"),
        .sdk(name: "AppKit", type: .framework),
        .sdk(name: "ApplicationServices", type: .framework),
        .sdk(name: "AVFAudio", type: .framework),
        .sdk(name: "CoreMedia", type: .framework),
        .external(name: "Fuse"),
        .sdk(name: "SwiftData", type: .framework),
        .sdk(name: "Speech", type: .framework),
        .sdk(name: "IOKit", type: .framework),
        .sdk(name: "ServiceManagement", type: .framework),
        .sdk(name: "UserNotifications", type: .framework),
        .external(name: "HarnessMonitorRegistry"),
        .target(name: "HarnessMonitorCloudKit")
    ]
    deps.append(contentsOf: FeatureFlags.kitAdditionalDependencies())
    return deps
}()

private let kitSettings: Settings = BuildSettings.frameworkSettings(
    bundleId: "io.harnessmonitor.kit",
    extraBase: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()]
)

private let kitTarget: Target = .target(
    name: "HarnessMonitorKit",
    destinations: macOSDestinations,
    product: .framework,
    bundleId: "io.harnessmonitor.kit",
    deploymentTargets: macOSDeploymentTargets,
    sources: kitSources,
    dependencies: kitDependencies,
    settings: kitSettings,
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:layer:core"])
)

private let policyModelsTarget: Target = .target(
    name: "HarnessMonitorPolicyModels",
    destinations: macOSDestinations,
    product: .staticFramework,
    bundleId: "io.harnessmonitor.policy-models",
    deploymentTargets: macOSDeploymentTargets,
    sources: policyModelSources,
    settings: staticFrameworkSettings(
        bundleId: "io.harnessmonitor.policy-models",
        moduleName: "HarnessMonitorPolicyModels"
    ),
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:feature:policy-canvas", "tag:layer:model"])
)

private let policyCanvasAlgorithmsTarget: Target = .target(
    name: "HarnessMonitorPolicyCanvasAlgorithms",
    destinations: macOSDestinations,
    product: .staticFramework,
    bundleId: "io.harnessmonitor.policy-canvas-algorithms",
    deploymentTargets: macOSDeploymentTargets,
    sources: policyCanvasAlgorithmSources,
    dependencies: [
        .target(name: "HarnessMonitorPolicyModels"),
        .external(name: "ElkSwift")
    ],
    settings: staticFrameworkSettings(
        bundleId: "io.harnessmonitor.policy-canvas-algorithms",
        moduleName: "HarnessMonitorPolicyCanvasAlgorithms",
        configurations: [
            .debug(name: "Debug", settings: [
                "SWIFT_COMPILATION_MODE": "wholemodule",
                "SWIFT_OPTIMIZATION_LEVEL": "-O"
            ]),
            .debug(name: "Preview", settings: [
                "SWIFT_COMPILATION_MODE": "wholemodule",
                "SWIFT_OPTIMIZATION_LEVEL": "-O"
            ]),
            .release(name: "Release")
        ]
    ),
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:feature:policy-canvas", "tag:layer:core"])
)

private let intentsSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorIntents/**/*.swift")
])

private let intentsSettings: Settings = BuildSettings.frameworkSettings(
    bundleId: "io.harnessmonitor.intents",
    extraBase: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()]
)

private let intentsTarget: Target = .target(
    name: "HarnessMonitorIntents",
    destinations: macOSDestinations,
    product: .framework,
    bundleId: "io.harnessmonitor.intents",
    deploymentTargets: macOSDeploymentTargets,
    sources: intentsSources,
    dependencies: [
        .target(name: "HarnessMonitorKit")
    ],
    settings: intentsSettings,
    metadata: .metadata(tags: ["tag:feature:intents", "tag:layer:integration"])
)

private let cloudKitSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorCloudKit/**/*.swift")
])

private let cloudKitTarget: Target = .target(
    name: "HarnessMonitorCloudKit",
    destinations: applePlatformDestinations,
    product: .staticFramework,
    bundleId: "io.harnessmonitor.cloudkit",
    deploymentTargets: applePlatformDeploymentTargets,
    sources: cloudKitSources,
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .sdk(name: "CloudKit", type: .framework)
    ],
    settings: staticFrameworkSettings(
        bundleId: "io.harnessmonitor.cloudkit",
        moduleName: "HarnessMonitorCloudKit"
    ),
    metadata: .metadata(tags: ["tag:feature:cloudkit", "tag:layer:integration"])
)

private let intentsExtensionTarget: Target = .target(
    name: "HarnessMonitorIntentsExtension",
    destinations: macOSDestinations,
    product: .appExtension,
    bundleId: "io.harnessmonitor.app.intents-extension",
    deploymentTargets: macOSDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitorIntentsExtension-Info.plist"),
    sources: ["Sources/HarnessMonitorIntentsExtension/**/*.swift"],
    entitlements: .file(path: "HarnessMonitorIntentsExtension.entitlements"),
    dependencies: [
        .target(name: "HarnessMonitorIntents")
    ],
    settings: .settings(
        base: [
            "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
            "CODE_SIGN_STYLE": "Automatic",
            "ENABLE_APP_SANDBOX": "YES",
            "ENABLE_INCOMING_NETWORK_CONNECTIONS": "NO",
            "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Resources/HarnessMonitorIntentsExtension-Info.plist",
            "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app.intents-extension",
            "PRODUCT_MODULE_NAME": "HarnessMonitorIntentsExtension",
            "PRODUCT_NAME": "HarnessMonitorIntentsExtension",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
        ]
    ),
    metadata: .metadata(tags: ["tag:feature:intents", "tag:layer:extension"])
)

private let widgetsExtensionTarget: Target = .target(
    name: "HarnessMonitorWidgets",
    destinations: macOSDestinations,
    product: .appExtension,
    bundleId: "io.harnessmonitor.app.widgets",
    deploymentTargets: macOSDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitorWidgets-Info.plist"),
    sources: ["Sources/HarnessMonitorWidgets/**/*.swift"],
    entitlements: .file(path: "HarnessMonitorWidgets.entitlements"),
    dependencies: [
        .target(name: "HarnessMonitorIntents"),
        .sdk(name: "WidgetKit", type: .framework),
        .sdk(name: "SwiftUI", type: .framework)
    ],
    settings: .settings(
        base: [
            "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
            "CODE_SIGN_STYLE": "Automatic",
            "ENABLE_APP_SANDBOX": "YES",
            "ENABLE_INCOMING_NETWORK_CONNECTIONS": "NO",
            "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Resources/HarnessMonitorWidgets-Info.plist",
            "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app.widgets",
            "PRODUCT_MODULE_NAME": "HarnessMonitorWidgets",
            "PRODUCT_NAME": "HarnessMonitorWidgets",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
        ]
    ),
    metadata: .metadata(tags: ["tag:feature:widgets", "tag:layer:extension"])
)

private let watchWidgetsTarget: Target = .target(
    name: "HarnessMonitorWatchWidgets",
    destinations: watchDestinations,
    product: .appExtension,
    bundleId: "io.harnessmonitor.app.ios.watch.widgets",
    deploymentTargets: watchDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitorWatchWidgets-Info.plist"),
    sources: ["Sources/HarnessMonitorWatchWidgets/**/*.swift"],
    resources: [
        "Resources/PrivacyInfo.xcprivacy",
        "Sources/HarnessMonitorWatchWidgets/Localizable.xcstrings",
    ],
    entitlements: .file(path: "HarnessMonitorWatchWidgets.entitlements"),
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .target(name: "HarnessMonitorCrypto"),
        .target(name: "HarnessMonitorCloudMirror"),
        .target(name: "HarnessMonitorCloudKit"),
        .sdk(name: "WidgetKit", type: .framework),
        .sdk(name: "SwiftUI", type: .framework)
    ],
    settings: .settings(
        base: [
            "CODE_SIGN_IDENTITY[sdk=watchos*]": "Apple Development",
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGNING_ALLOWED": "YES",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Resources/HarnessMonitorWatchWidgets-Info.plist",
            "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app.ios.watch.widgets",
            "PRODUCT_MODULE_NAME": "HarnessMonitorWatchWidgets",
            "PRODUCT_NAME": "HarnessMonitorWatchWidgets",
            "SDKROOT": "watchos",
            "SUPPORTED_PLATFORMS": "watchos watchsimulator",
            "TARGETED_DEVICE_FAMILY": "4",
            "WATCHOS_DEPLOYMENT_TARGET": "26.0"
        ]
    ),
    metadata: .metadata(tags: ["tag:feature:watch", "tag:layer:extension"])
)

private let watchAppTarget: Target = .target(
    name: "HarnessMonitorWatch",
    destinations: watchDestinations,
    product: .app,
    bundleId: "io.harnessmonitor.app.ios.watch",
    deploymentTargets: watchDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitorWatch-Info.plist"),
    sources: ["Sources/HarnessMonitorWatch/**/*.swift"],
    resources: [
        "Sources/HarnessMonitorWatch/Assets.xcassets",
        "Resources/PrivacyInfo.xcprivacy",
        "Sources/HarnessMonitorWatch/Localizable.xcstrings",
    ],
    entitlements: .file(path: "HarnessMonitorWatch.entitlements"),
    dependencies: [
        .target(name: "HarnessMonitorCloudKit"),
        .target(name: "HarnessMonitorCore"),
        .target(name: "HarnessMonitorCrypto"),
        .target(name: "HarnessMonitorCloudMirror"),
        .target(name: "HarnessMonitorMirrorStore"),
        .target(name: "HarnessMonitorWatchWidgets"),
        .sdk(name: "LocalAuthentication", type: .framework),
        .sdk(name: "WatchConnectivity", type: .framework),
        .sdk(name: "WidgetKit", type: .framework)
    ],
    settings: .settings(
        base: [
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CODE_SIGN_IDENTITY[sdk=watchos*]": "Apple Development",
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGNING_ALLOWED": "YES",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "Resources/HarnessMonitorWatch-Info.plist",
            "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app.ios.watch",
            "PRODUCT_MODULE_NAME": "HarnessMonitorWatch",
            "PRODUCT_NAME": "Harness Monitor",
            "SDKROOT": "watchos",
            "SUPPORTED_PLATFORMS": "watchos watchsimulator",
            "TARGETED_DEVICE_FAMILY": "4",
            "WATCHOS_DEPLOYMENT_TARGET": "26.0"
        ]
    ),
    metadata: .metadata(tags: ["tag:feature:watch", "tag:layer:app"])
)

private let mobileAppTarget: Target = .target(
    name: "HarnessMonitorMobile",
    destinations: iOSDestinations,
    product: .app,
    bundleId: "io.harnessmonitor.app",
    deploymentTargets: iOSDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitorMobile-Info.plist"),
    sources: ["Sources/HarnessMonitorMobile/**/*.swift"],
    resources: [
        "Sources/HarnessMonitorMobile/Assets.xcassets",
        "Resources/PrivacyInfo.xcprivacy",
        "Sources/HarnessMonitorMobile/Localizable.xcstrings",
    ],
    entitlements: .file(path: "HarnessMonitorMobile.entitlements"),
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .target(name: "HarnessMonitorCrypto"),
        .target(name: "HarnessMonitorCloudMirror"),
        .target(name: "HarnessMonitorCloudKit"),
        .target(name: "HarnessMonitorMirrorStore"),
        .target(name: "HarnessMonitorWatch"),
        .target(name: "HarnessMonitorMobileWidgets"),
        .sdk(name: "SwiftUI", type: .framework),
        .sdk(name: "ActivityKit", type: .framework),
        .sdk(name: "LocalAuthentication", type: .framework),
        .sdk(name: "UserNotifications", type: .framework),
        .sdk(name: "WatchConnectivity", type: .framework),
        .sdk(name: "VisionKit", type: .framework)
    ],
    settings: .settings(base: [
        "CODE_SIGN_IDENTITY[sdk=iphoneos*]": "Apple Development",
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGNING_ALLOWED": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/HarnessMonitorMobile-Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app",
        "PRODUCT_MODULE_NAME": "HarnessMonitorMobile",
        "PRODUCT_NAME": "Harness Monitor",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:app"])
)

private let mobileWidgetsTarget: Target = .target(
    name: "HarnessMonitorMobileWidgets",
    destinations: iOSDestinations,
    product: .appExtension,
    bundleId: "io.harnessmonitor.app.ios.widgets",
    deploymentTargets: iOSDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitorMobileWidgets-Info.plist"),
    sources: ["Sources/HarnessMonitorMobileWidgets/**/*.swift"],
    resources: [
        "Resources/PrivacyInfo.xcprivacy",
        "Sources/HarnessMonitorMobileWidgets/Localizable.xcstrings",
    ],
    entitlements: .file(path: "HarnessMonitorMobileWidgets.entitlements"),
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .target(name: "HarnessMonitorCrypto"),
        .target(name: "HarnessMonitorCloudMirror"),
        .target(name: "HarnessMonitorCloudKit"),
        .sdk(name: "ActivityKit", type: .framework),
        .sdk(name: "WidgetKit", type: .framework),
        .sdk(name: "SwiftUI", type: .framework)
    ],
    settings: .settings(base: [
        "CODE_SIGN_IDENTITY[sdk=iphoneos*]": "Apple Development",
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGNING_ALLOWED": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/HarnessMonitorMobileWidgets-Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app.ios.widgets",
        "PRODUCT_MODULE_NAME": "HarnessMonitorMobileWidgets",
        "PRODUCT_NAME": "HarnessMonitorMobileWidgets",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:feature:widgets", "tag:layer:extension"])
)

private let policyCanvasTarget: Target = {
    var deps: [TargetDependency] = [
        .target(name: "HarnessMonitorKit"),
        .target(name: "HarnessMonitorPolicyCanvasAlgorithms")
    ]
    deps.append(contentsOf: FeatureFlags.uiPreviewableAdditionalDependencies())
    return .target(
        name: "HarnessMonitorPolicyCanvas",
        destinations: macOSDestinations,
        product: .framework,
        bundleId: "io.harnessmonitor.policy-canvas",
        deploymentTargets: macOSDeploymentTargets,
        sources: policyCanvasSources,
        resources: ["Sources/HarnessMonitorUIPreviewable/Assets.xcassets"],
        dependencies: deps,
        settings: .settings(
            base: [
                "CODE_SIGN_STYLE": "Automatic",
                "CODE_SIGNING_ALLOWED": "YES",
                "ENABLE_MODULE_VERIFIER": "YES",
                "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
                "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu17 gnu++20",
                "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.policy-canvas",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
            ],
            configurations: [
                .debug(name: "Debug", settings: BuildSettings.canvasPreviewCompilationOverrides),
                .debug(name: "Preview", settings: BuildSettings.canvasPreviewCompilationOverrides),
                .release(name: "Release")
            ]
        ),
        metadata: .metadata(tags: ["tag:feature:monitor", "tag:feature:policy-canvas", "tag:layer:ui"])
    )
}()

private let uiPreviewableTarget: Target = {
    var deps: [TargetDependency] = [
        .target(name: "HarnessMonitorKit"),
        .target(name: "HarnessMonitorIntents"),
        .target(name: "HarnessMonitorPolicyCanvas"),
        .sdk(name: "SwiftData", type: .framework),
        .sdk(name: "Vision", type: .framework)
    ]
    deps.append(contentsOf: FeatureFlags.uiPreviewableAdditionalDependencies())
    return .target(
        name: "HarnessMonitorUIPreviewable",
        destinations: macOSDestinations,
        product: .framework,
        bundleId: "io.harnessmonitor.ui.previewable",
        deploymentTargets: macOSDeploymentTargets,
        sources: uiPreviewableSources,
        resources: ["Sources/HarnessMonitorUIPreviewable/Assets.xcassets"],
        dependencies: deps,
        settings: .settings(
            base: [
                "CODE_SIGN_STYLE": "Automatic",
                "CODE_SIGNING_ALLOWED": "YES",
                "ENABLE_MODULE_VERIFIER": "YES",
                "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
                "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu17 gnu++20",
                "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.ui.previewable",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
            ],
            configurations: [
                .debug(name: "Debug", settings: BuildSettings.canvasPreviewCompilationOverrides),
                .debug(name: "Preview", settings: BuildSettings.canvasPreviewCompilationOverrides),
                .release(name: "Release")
            ]
        ),
        metadata: .metadata(tags: ["tag:feature:monitor", "tag:feature:previews", "tag:layer:ui"])
    )
}()

private let previewHostTarget: Target = .target(
    name: "HarnessMonitorPreviewHost",
    destinations: macOSDestinations,
    product: .app,
    bundleId: "io.harnessmonitor.previews",
    deploymentTargets: macOSDeploymentTargets,
    sources: ["Sources/HarnessMonitorPreviewHost/**/*.swift"],
    entitlements: .file(path: "HarnessMonitorPreviewHost.entitlements"),
    dependencies: [
        .target(name: "HarnessMonitorKit"),
        .target(name: "HarnessMonitorUIPreviewable")
    ],
    settings: .settings(
        base: [
            "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGNING_ALLOWED": "YES",
            "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.previews",
            "PRODUCT_NAME": "HarnessMonitorPreviewHost",
            "INFOPLIST_KEY_NSPrincipalClass": "NSApplication",
            "INFOPLIST_KEY_NSHumanReadableCopyright": "",
            "INFOPLIST_KEY_LSUIElement": "YES"
        ],
        configurations: [
            .debug(name: "Debug"),
            .debug(name: "Preview", settings: [
                "COMPILER_INDEX_STORE_ENABLE": "NO",
                "ONLY_ACTIVE_ARCH": "YES",
                "SWIFT_ENABLE_EAGER_LINKING": "NO",
                "SWIFT_ENABLE_PREFIX_MAPPING": "NO"
            ]),
            .release(name: "Release")
        ]
    ),
    metadata: .metadata(tags: ["tag:feature:previews", "tag:layer:app"])
)

private let policyCanvasLabHostTarget: Target = .target(
    name: "HarnessMonitorPolicyCanvasLab",
    destinations: macOSDestinations,
    product: .app,
    bundleId: "io.harnessmonitor.policy-canvas-lab",
    deploymentTargets: macOSDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitor-Info.plist"),
    sources: ["Sources/HarnessMonitorPolicyCanvasLabHost/**/*.swift"],
    dependencies: [.target(name: "HarnessMonitorPolicyCanvas")],
    settings: .settings(base: [
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "CODE_SIGN_STYLE": "Automatic",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/HarnessMonitor-Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.policy-canvas-lab",
        "PRODUCT_MODULE_NAME": "HarnessMonitorPolicyCanvasLab",
        "PRODUCT_NAME": "Harness Monitor Policy Canvas Lab",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:feature:policy-canvas", "tag:layer:app"])
)

private let monitorAppDependencies: [TargetDependency] = {
    var deps: [TargetDependency] = [
        .target(name: "HarnessMonitorKit"),
        .target(name: "HarnessMonitorIntents"),
        .target(name: "HarnessMonitorMacRelay"),
        .target(name: "HarnessMonitorPolicyCanvas"),
        .target(name: "HarnessMonitorUIPreviewable")
    ]
    deps.append(contentsOf: FeatureFlags.appAdditionalDependencies())
    return deps
}()

// Production-app dependencies embed the App Intents extension as a plug-in.
// HarnessMonitorUITestHost cannot embed it because its bundle id
// `io.harnessmonitor.app.ui-testing` is not a prefix of
// `io.harnessmonitor.app.intents-extension`, which would trip the
// ValidateEmbeddedBinary build step.
private let monitorProductionAppDependencies: [TargetDependency] =
    monitorAppDependencies + [
        .target(name: "HarnessMonitorIntentsExtension"),
        .target(name: "HarnessMonitorWidgets")
    ]

private let monitorAppSettings: Settings = .settings(
    base: [
        "CODE_SIGN_ENTITLEMENTS": generatedAppEntitlements,
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "CODE_SIGN_STYLE": "Automatic",
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_INCOMING_NETWORK_CONNECTIONS": "NO",
        "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/HarnessMonitor-Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app",
        "PRODUCT_MODULE_NAME": "HarnessMonitor",
        "PRODUCT_NAME": "Harness Monitor",
        "REGISTER_APP_GROUPS": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]
)

private let monitorAppTarget: Target = .target(
    name: "HarnessMonitor",
    destinations: macOSDestinations,
    product: .app,
    bundleId: "io.harnessmonitor.app",
    deploymentTargets: macOSDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitor-Info.plist"),
    sources: monitorAppSources,
    resources: [
        "Sources/HarnessMonitor/Assets.xcassets",
        "Resources/HarnessMonitorPerfScenarios.json",
        "Resources/PrivacyInfo.xcprivacy",
    ],
    entitlements: .file(path: xcodeVisibleAppEntitlementsPath),
    scripts: [
        BuildPhases.bundleDaemonAgent(),
        BuildPhases.clearGatekeeperMetadata(variant: .monitorApp)
    ],
    dependencies: monitorProductionAppDependencies,
    settings: monitorAppSettings,
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:layer:app"])
)

// External-daemon variant: same sources and dependencies as `HarnessMonitor`
// but built without the macOS app sandbox so the running app can reach a
// developer-launched `harness daemon dev` outside its own container. SMAppService
// registration is skipped at runtime via `HARNESS_MONITOR_EXTERNAL_DAEMON=1`, so
// the bundled managed plist stays inert; we still ship the helper binary in the
// .app to keep the layout identical to the sandboxed product.
// Reuse the regular app's bundle ID so the existing automatic-signing
// provisioning profile covers both variants and user defaults stay shared. The
// external-daemon app is intentionally unsandboxed, so it resolves app-group
// files through the home-relative fallback instead of carrying the app-group
// entitlement that only the sandboxed app targets need. The two products live
// side-by-side in DerivedData thanks to their distinct PRODUCT_NAME values, and
// `HARNESS_MONITOR_EXTERNAL_DAEMON=1` is what actually selects external-daemon
// runtime behavior at launch.
private let externalDaemonAppSettings: Settings = .settings(
    base: [
        "CODE_SIGN_ENTITLEMENTS": generatedAppEntitlements,
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "CODE_SIGN_STYLE": "Automatic",
        "ENABLE_APP_SANDBOX": "NO",
        "ENABLE_INCOMING_NETWORK_CONNECTIONS": "NO",
        "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/HarnessMonitor-Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app",
        "PRODUCT_MODULE_NAME": "HarnessMonitor",
        "PRODUCT_NAME": "Harness Monitor (External Daemon)",
        "REGISTER_APP_GROUPS": "NO",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]
)

private let externalDaemonAppTarget: Target = .target(
    name: "HarnessMonitorExternalDaemon",
    destinations: macOSDestinations,
    product: .app,
    bundleId: "io.harnessmonitor.app",
    deploymentTargets: macOSDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitor-Info.plist"),
    sources: monitorAppSources,
    resources: [
        "Sources/HarnessMonitor/Assets.xcassets",
        "Resources/HarnessMonitorPerfScenarios.json",
        "Resources/PrivacyInfo.xcprivacy",
    ],
    entitlements: .file(path: xcodeVisibleExternalDaemonEntitlementsPath),
    scripts: [
        BuildPhases.bundleDaemonAgent(),
        BuildPhases.clearGatekeeperMetadata(variant: .monitorApp)
    ],
    dependencies: monitorProductionAppDependencies,
    settings: externalDaemonAppSettings,
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:layer:app"])
)

private let uiTestHostSettings: Settings = .settings(
    base: [
        "CODE_SIGN_ENTITLEMENTS": generatedAppEntitlements,
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
        "CODE_SIGN_STYLE": "Automatic",
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_INCOMING_NETWORK_CONNECTIONS": "NO",
        "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/HarnessMonitor-Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app.ui-testing",
        "PRODUCT_NAME": "Harness Monitor UI Testing",
        "REGISTER_APP_GROUPS": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]
)

private let uiTestHostTarget: Target = .target(
    name: "HarnessMonitorUITestHost",
    destinations: macOSDestinations,
    product: .app,
    bundleId: "io.harnessmonitor.app.ui-testing",
    deploymentTargets: macOSDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitor-Info.plist"),
    sources: monitorAppSources,
    resources: [
        "Sources/HarnessMonitor/Assets.xcassets",
        "Resources/HarnessMonitorPerfScenarios.json",
        "Resources/PrivacyInfo.xcprivacy",
    ],
    entitlements: .file(path: xcodeVisibleAppEntitlementsPath),
    scripts: [
        BuildPhases.bundleDaemonAgent(),
        BuildPhases.clearGatekeeperMetadata(variant: .uiTestHost)
    ],
    dependencies: monitorAppDependencies,
    settings: uiTestHostSettings,
    metadata: .metadata(tags: ["tag:feature:ui-testing", "tag:layer:app"])
)

// Agent/audit-isolated variant of the production app: identical sources and
// live scene tree, but a distinct lane-scoped bundle id so LaunchServices never
// hands a launch off to the developer's running `io.harnessmonitor.app`, minimal
// entitlements so automatic signing provisions any lane id without iCloud or
// app-group registration, no embedded extensions, and its own UserDefaults
// domain. Daemon isolation still comes from the runtime lane.
private let isolatedAppSettings: Settings = .settings(
    base: [
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "CODE_SIGN_STYLE": "Automatic",
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_INCOMING_NETWORK_CONNECTIONS": "NO",
        "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/HarnessMonitor-Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": .string(isolatedAppBundleId),
        "PRODUCT_NAME": "Harness Monitor Isolated",
        "REGISTER_APP_GROUPS": "NO",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]
)

private let isolatedAppTarget: Target = .target(
    name: "HarnessMonitorIsolated",
    destinations: macOSDestinations,
    product: .app,
    bundleId: isolatedAppBundleId,
    deploymentTargets: macOSDeploymentTargets,
    infoPlist: .file(path: "Resources/HarnessMonitor-Info.plist"),
    sources: monitorAppSources,
    resources: [
        "Sources/HarnessMonitor/Assets.xcassets",
        "Resources/HarnessMonitorPerfScenarios.json",
        "Resources/PrivacyInfo.xcprivacy",
    ],
    entitlements: .file(path: isolatedAppEntitlementsPath),
    dependencies: monitorAppDependencies,
    settings: isolatedAppSettings,
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:layer:app"])
)

private let appTestsEnv: [String: EnvironmentVariable] = [
    "HARNESS_DAEMON_DATA_HOME": .environmentVariable(value: "/tmp/harness-monitor-tests", isEnabled: true),
    "HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE": .environmentVariable(value: "1", isEnabled: true),
    "HARNESS_MONITOR_LAUNCH_MODE": .environmentVariable(value: "preview", isEnabled: true)
]

private let appTestsSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Tests/HarnessMonitorAppTests/**/*.swift", excluding: [
        "Tests/HarnessMonitorAppTests/PolicyCanvasLabSamplesTests.swift",
        "Tests/HarnessMonitorAppTests/PolicyCanvasLabPickerRuntimeTests.swift",
        "Tests/HarnessMonitorAppTests/PolicyCanvasLabRoutingQualityTests.swift"
    ])
])

private let appTestsTarget: Target = .target(
    name: "HarnessMonitorAppTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.app-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: appTestsSources,
    dependencies: [.target(name: "HarnessMonitor"), .target(name: "HarnessMonitorPolicyCanvas")],
    settings: .settings(base: [
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting(),
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Harness Monitor.app/Contents/MacOS/Harness Monitor"
    ]),
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:layer:test"])
)

private let appTestsScheme: Scheme = .scheme(
    name: "HarnessMonitorAppTests",
    shared: true,
    buildAction: .buildAction(
        targets: [.target("HarnessMonitorAppTests")],
        preActions: [BuildPhases.prepareAppEntitlementsPreAction()]
    ),
    testAction: .targets(
        [.testableTarget(target: .target("HarnessMonitorAppTests"))],
        arguments: Arguments.arguments(environmentVariables: appTestsEnv),
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let kitTestsSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Tests/HarnessMonitorKitTests/**/*.swift", excluding: [
        "Tests/HarnessMonitorKitTests/Features/**",
        "Tests/HarnessMonitorKitTests/PolicyCanvas*.swift"
    ])
] + FeatureFlags.kitTestsAdditionalSourceGlobs())

private let policyCanvasTestsSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Tests/HarnessMonitorPolicyCanvasTests/**/*.swift")
])

private let policyCanvasAlgorithmTestsSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Tests/HarnessMonitorPolicyCanvasAlgorithmTests/**/*.swift")
])

private let kitTestsTarget: Target = .target(
    name: "HarnessMonitorKitTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.kit-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: kitTestsSources,
    dependencies: [
        // CloudKit is embedded in HarnessMonitorKit (a dynamic framework), so
        // depending on it here too would re-link the static product into the
        // test bundle. Kit propagates the module for `import`; do not re-link.
        .target(name: "HarnessMonitorKit"),
        .target(name: "HarnessMonitorPolicyCanvas"),
        .target(name: "HarnessMonitorUIPreviewable")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.kit-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:layer:test"])
)

private let policyCanvasTestsTarget: Target = .target(
    name: "HarnessMonitorPolicyCanvasTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.policy-canvas-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: policyCanvasTestsSources,
    dependencies: [
        .target(name: "HarnessMonitorKit"),
        .target(name: "HarnessMonitorPolicyCanvas"),
        .target(name: "HarnessMonitorPolicyCanvasAlgorithms")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.policy-canvas-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:feature:policy-canvas", "tag:layer:test"])
)

private let policyCanvasAlgorithmTestsTarget: Target = .target(
    name: "HarnessMonitorPolicyCanvasAlgorithmTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.policy-canvas-algorithm-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: policyCanvasAlgorithmTestsSources,
    dependencies: [
        .target(name: "HarnessMonitorPolicyCanvasAlgorithms")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.policy-canvas-algorithm-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:feature:policy-canvas", "tag:feature:algorithms", "tag:layer:test"])
)

private let intentsTestsSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Tests/HarnessMonitorIntentsTests/**/*.swift")
])

private let intentsTestsTarget: Target = .target(
    name: "HarnessMonitorIntentsTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.intents-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: intentsTestsSources,
    dependencies: [
        .target(name: "HarnessMonitorIntents"),
        .target(name: "HarnessMonitorKit")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.intents-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:intents", "tag:layer:test"])
)

private let cloudKitTestsSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Tests/HarnessMonitorCloudKitTests/**/*.swift")
])

private let cloudKitTestsTarget: Target = .target(
    name: "HarnessMonitorCloudKitTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.cloudkit-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: cloudKitTestsSources,
    dependencies: [
        .target(name: "HarnessMonitorCloudKit")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.cloudkit-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:cloudkit", "tag:layer:test"])
)

private let coreTestsTarget: Target = .target(
    name: "HarnessMonitorCoreTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.core-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: ["Tests/HarnessMonitorCoreTests/**/*.swift"],
    dependencies: [
        .target(name: "HarnessMonitorCore")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.core-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:test"])
)

private let mirrorStoreTestsTarget: Target = .target(
    name: "HarnessMonitorMirrorStoreTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.mirrorstore-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: ["Tests/HarnessMonitorMirrorStoreTests/**/*.swift"],
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .target(name: "HarnessMonitorCrypto"),
        .target(name: "HarnessMonitorCloudMirror"),
        .target(name: "HarnessMonitorMirrorStore")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.mirrorstore-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:test"])
)

private let cryptoTestsTarget: Target = .target(
    name: "HarnessMonitorCryptoTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.crypto-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: ["Tests/HarnessMonitorCryptoTests/**/*.swift"],
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .target(name: "HarnessMonitorCrypto")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.crypto-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:test"])
)

private let cloudMirrorTestsTarget: Target = .target(
    name: "HarnessMonitorCloudMirrorTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.cloudmirror-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: ["Tests/HarnessMonitorCloudMirrorTests/**/*.swift"],
    dependencies: [
        .target(name: "HarnessMonitorCore"),
        .target(name: "HarnessMonitorCrypto"),
        .target(name: "HarnessMonitorCloudMirror")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.cloudmirror-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:test"])
)

private let macRelayTestsTarget: Target = .target(
    name: "HarnessMonitorMacRelayTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.mac-relay-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: ["Tests/HarnessMonitorMacRelayTests/**/*.swift"],
    dependencies: [
        // Core, Crypto, and CloudMirror are embedded in HarnessMonitorMacRelay
        // (a dynamic framework). Depending on them here too would re-link the
        // static products into the test bundle. MacRelay propagates their
        // modules for `import`; depend only on the framework under test.
        .target(name: "HarnessMonitorMacRelay")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.mac-relay-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:mobile", "tag:layer:test"])
)

private let uiTestsTarget: Target = .target(
    name: "HarnessMonitorUITests",
    destinations: macOSDestinations,
    product: .uiTests,
    bundleId: "io.harnessmonitor.ui-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: [
        "Tests/HarnessMonitorUITestSupport/**/*.swift",
        "Tests/HarnessMonitorUITests/**/*.swift"
    ],
    resources: ["Resources/HarnessMonitorPerfScenarios.json"],
    scripts: [BuildPhases.stripTestBundleXattrs()],
    dependencies: [
        .target(name: "HarnessMonitorUITestHost")
    ],
    settings: .settings(base: [
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "CODE_SIGNING_ALLOWED": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.ui-tests",
        "TEST_TARGET_NAME": "HarnessMonitorUITestHost"
    ]),
    metadata: .metadata(tags: ["tag:feature:ui-testing", "tag:layer:test"])
)

private let agentsE2ETarget: Target = .target(
    name: "HarnessMonitorAgentsE2ETests",
    destinations: macOSDestinations,
    product: .uiTests,
    bundleId: "io.harnessmonitor.agents-e2e-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: [
        "Tests/HarnessMonitorUITestSupport/**/*.swift",
        "Tests/HarnessMonitorAgentsE2ETests/**/*.swift"
    ],
    scripts: [BuildPhases.stripTestBundleXattrs()],
    dependencies: [
        .target(name: "HarnessMonitorUITestHost")
    ],
    settings: .settings(base: [
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "CODE_SIGNING_ALLOWED": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.agents-e2e-tests",
        "TEST_TARGET_NAME": "HarnessMonitorUITestHost"
    ]),
    metadata: .metadata(tags: ["tag:feature:agents", "tag:layer:test"])
)

private let monitorRunEnv: [String: EnvironmentVariable] = [
    "HARNESS_OTEL_EXPORT": .environmentVariable(value: "1", isEnabled: true),
    "OTEL_EXPORTER_OTLP_ENDPOINT": .environmentVariable(value: "http://127.0.0.1:4317", isEnabled: true),
    "MTL_DEBUG_LAYER": .environmentVariable(value: "0", isEnabled: true),
    "SWIFTUI_VIEW_DEBUG": .environmentVariable(value: "0", isEnabled: true),
    // Pin the regular scheme to managed daemon mode so it ignores any
    // persisted external-daemon preference from prior runs of the
    // sibling scheme or Settings UI.
    "HARNESS_MONITOR_EXTERNAL_DAEMON": .environmentVariable(value: "0", isEnabled: true),
]

private let monitorTestEnv: [String: EnvironmentVariable] = [
    "HARNESS_DAEMON_DATA_HOME": .environmentVariable(value: "/tmp/harness-monitor-tests", isEnabled: true)
]

private let externalDaemonRunEnv: [String: EnvironmentVariable] = monitorRunEnv.merging([
    "HARNESS_MONITOR_EXTERNAL_DAEMON": .environmentVariable(value: "1", isEnabled: true),
    "HARNESS_BOOTSTRAP_TIMEOUT_SECONDS": .environmentVariable(value: "60", isEnabled: true)
]) { _, new in new }

private let monitorScheme: Scheme = .scheme(
    name: "HarnessMonitor",
    shared: true,
    buildAction: .buildAction(
        targets: [
            .target("HarnessMonitor"),
            .target("HarnessMonitorKit"),
            .target("HarnessMonitorUIPreviewable")
        ],
        preActions: [
            BuildPhases.prepareAppEntitlementsPreAction(),
            BuildPhases.daemonBuildPreAction()
        ]
    ),
    testAction: .targets(
        [
            .testableTarget(target: .target("HarnessMonitorKitTests")),
            .testableTarget(target: .target("HarnessMonitorIntentsTests")),
            .testableTarget(target: .target("HarnessMonitorCloudKitTests")),
            .testableTarget(target: .target("HarnessMonitorAppTests")),
            .testableTarget(target: .target("HarnessMonitorUITests"))
        ],
        arguments: Arguments.arguments(environmentVariables: monitorTestEnv),
        configuration: "Debug",
        options: .options(coverage: true)
    ),
    runAction: .runAction(
        configuration: "Debug",
        executable: .target("HarnessMonitor"),
        arguments: Arguments.arguments(environmentVariables: monitorRunEnv)
    )
)

private let kitTestsScheme: Scheme = .scheme(
    name: "HarnessMonitorKitTests",
    shared: true,
    buildAction: .buildAction(targets: [.target("HarnessMonitorKitTests")]),
    testAction: .targets(
        [.testableTarget(target: .target("HarnessMonitorKitTests"))],
        arguments: Arguments.arguments(environmentVariables: monitorTestEnv),
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let policyCanvasTestsScheme: Scheme = .scheme(
    name: "HarnessMonitorPolicyCanvasTests",
    shared: true,
    buildAction: .buildAction(targets: [.target("HarnessMonitorPolicyCanvasTests")]),
    testAction: .targets(
        [.testableTarget(target: .target("HarnessMonitorPolicyCanvasTests"))],
        arguments: Arguments.arguments(environmentVariables: monitorTestEnv),
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let policyCanvasAlgorithmTestsScheme: Scheme = .scheme(
    name: "HarnessMonitorPolicyCanvasAlgorithmTests",
    shared: true,
    buildAction: .buildAction(targets: [.target("HarnessMonitorPolicyCanvasAlgorithmTests")]),
    testAction: .targets(
        [.testableTarget(target: .target("HarnessMonitorPolicyCanvasAlgorithmTests"))],
        arguments: Arguments.arguments(environmentVariables: monitorTestEnv),
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let intentsTestsScheme: Scheme = .scheme(
    name: "HarnessMonitorIntentsTests",
    shared: true,
    buildAction: .buildAction(targets: [.target("HarnessMonitorIntentsTests")]),
    testAction: .targets(
        [.testableTarget(target: .target("HarnessMonitorIntentsTests"))],
        arguments: Arguments.arguments(environmentVariables: monitorTestEnv),
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let cloudKitTestsScheme: Scheme = .scheme(
    name: "HarnessMonitorCloudKitTests",
    shared: true,
    buildAction: .buildAction(targets: [.target("HarnessMonitorCloudKitTests")]),
    testAction: .targets(
        [.testableTarget(target: .target("HarnessMonitorCloudKitTests"))],
        arguments: Arguments.arguments(environmentVariables: monitorTestEnv),
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let cryptoScheme: Scheme = .scheme(
    name: "HarnessMonitorCrypto",
    shared: true,
    buildAction: .buildAction(targets: [
        .target("HarnessMonitorCore"),
        .target("HarnessMonitorCrypto")
    ])
)

private let cryptoTestsScheme: Scheme = .scheme(
    name: "HarnessMonitorCryptoTests",
    shared: true,
    buildAction: .buildAction(targets: [.target("HarnessMonitorCryptoTests")]),
    testAction: .targets(
        [.testableTarget(target: .target("HarnessMonitorCryptoTests"))],
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let cloudMirrorTestsScheme: Scheme = .scheme(
    name: "HarnessMonitorCloudMirrorTests",
    shared: true,
    buildAction: .buildAction(targets: [.target("HarnessMonitorCloudMirrorTests")]),
    testAction: .targets(
        [.testableTarget(target: .target("HarnessMonitorCloudMirrorTests"))],
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let macRelayTestsScheme: Scheme = .scheme(
    name: "HarnessMonitorMacRelayTests",
    shared: true,
    buildAction: .buildAction(targets: [.target("HarnessMonitorMacRelayTests")]),
    testAction: .targets(
        [.testableTarget(target: .target("HarnessMonitorMacRelayTests"))],
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let mobileFoundationTestsScheme: Scheme = .scheme(
    name: "HarnessMonitorMobileFoundationTests",
    shared: true,
    buildAction: .buildAction(targets: [
        .target("HarnessMonitorCoreTests"),
        .target("HarnessMonitorMirrorStoreTests"),
        .target("HarnessMonitorCryptoTests"),
        .target("HarnessMonitorCloudMirrorTests"),
        .target("HarnessMonitorMacRelayTests")
    ]),
    testAction: .targets(
        [
            .testableTarget(target: .target("HarnessMonitorCoreTests")),
            .testableTarget(target: .target("HarnessMonitorMirrorStoreTests")),
            .testableTarget(target: .target("HarnessMonitorCryptoTests")),
            .testableTarget(target: .target("HarnessMonitorCloudMirrorTests")),
            .testableTarget(target: .target("HarnessMonitorMacRelayTests"))
        ],
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let externalDaemonScheme: Scheme = .scheme(
    name: "HarnessMonitor (External Daemon)",
    shared: true,
    buildAction: .buildAction(targets: [
        .target("HarnessMonitorExternalDaemon"),
        .target("HarnessMonitorKit"),
        .target("HarnessMonitorUIPreviewable")
    ], preActions: [BuildPhases.prepareAppEntitlementsPreAction()]),
    runAction: .runAction(
        configuration: "Debug",
        executable: .target("HarnessMonitorExternalDaemon"),
        arguments: Arguments.arguments(environmentVariables: externalDaemonRunEnv)
    )
)

private let uiTestHostScheme: Scheme = .scheme(
    name: "HarnessMonitorUITestHost",
    shared: true,
    buildAction: .buildAction(
        targets: [.target("HarnessMonitorUITestHost")],
        preActions: [BuildPhases.prepareAppEntitlementsPreAction()]
    ),
    runAction: .runAction(
        configuration: "Debug",
        executable: .target("HarnessMonitorUITestHost")
    )
)

private let isolatedScheme: Scheme = .scheme(
    name: "HarnessMonitorIsolated",
    shared: true,
    buildAction: .buildAction(targets: [
        .target("HarnessMonitorIsolated"),
        .target("HarnessMonitorKit"),
        .target("HarnessMonitorUIPreviewable")
    ]),
    runAction: .runAction(
        configuration: "Debug",
        executable: .target("HarnessMonitorIsolated")
    )
)

private let agentsE2EScheme: Scheme = .scheme(
    name: "HarnessMonitorAgentsE2E",
    shared: true,
    buildAction: .buildAction(
        targets: [
            .target("HarnessMonitor"),
            .target("HarnessMonitorKit"),
            .target("HarnessMonitorUIPreviewable")
        ],
        preActions: [
            BuildPhases.prepareAppEntitlementsPreAction(),
            BuildPhases.daemonBuildPreAction()
        ]
    ),
    testAction: .targets(
        [.testableTarget(target: .target("HarnessMonitorAgentsE2ETests"))],
        configuration: "Debug",
        options: .options(coverage: true)
    )
)

private let watchAppScheme: Scheme = .scheme(
    name: "HarnessMonitorWatch",
    shared: true,
    buildAction: .buildAction(targets: [.target("HarnessMonitorWatch")]),
    runAction: .runAction(
        configuration: "Debug",
        executable: .target("HarnessMonitorWatch")
    )
)

private let mobileAppScheme: Scheme = .scheme(
    name: "HarnessMonitorMobile",
    shared: true,
    buildAction: .buildAction(targets: [
        .target("HarnessMonitorMobile"),
        .target("HarnessMonitorMobileWidgets"),
        .target("HarnessMonitorCore"),
        .target("HarnessMonitorCrypto"),
        .target("HarnessMonitorCloudMirror")
    ]),
    runAction: .runAction(
        configuration: "Debug",
        executable: .target("HarnessMonitorMobile")
    )
)

private let uiPreviewableScheme: Scheme = .scheme(
    name: "HarnessMonitorUIPreviewable",
    shared: true,
    buildAction: .buildAction(targets: [.target("HarnessMonitorUIPreviewable")]),
    testAction: .targets(
        [],
        configuration: "Preview",
        expandVariableFromTarget: "HarnessMonitorUIPreviewable"
    ),
    runAction: .runAction(configuration: "Preview"),
    analyzeAction: .analyzeAction(configuration: "Preview")
)

private let policyCanvasLabHostScheme: Scheme = .scheme(
    name: "HarnessMonitorPolicyCanvasLab",
    shared: true,
    buildAction: .buildAction(targets: [
        .target("HarnessMonitorPolicyCanvasLab"),
        .target("HarnessMonitorPolicyCanvas")
    ]),
    runAction: .runAction(
        configuration: "Debug",
        executable: .target("HarnessMonitorPolicyCanvasLab")
    )
)

private let uiPreviewsScheme: Scheme = .scheme(
    name: "HarnessMonitorUIPreviews",
    shared: true,
    buildAction: .buildAction(targets: [
        .target("HarnessMonitorPreviewHost"),
        .target("HarnessMonitorUIPreviewable"),
        .target("HarnessMonitorKit")
    ]),
    testAction: .targets(
        [],
        configuration: "Preview",
        expandVariableFromTarget: "HarnessMonitorPreviewHost"
    ),
    runAction: .runAction(
        configuration: "Preview",
        executable: .target("HarnessMonitorPreviewHost")
    ),
    analyzeAction: .analyzeAction(configuration: "Preview")
)

let project = Project(
    name: "HarnessMonitor",
    options: .options(
        automaticSchemesOptions: .disabled,
        defaultKnownRegions: ["en"],
        developmentRegion: "en"
    ),
    settings: BuildSettings.projectSettings(),
    targets: [
        coreTarget,
        cryptoTarget,
        cloudMirrorTarget,
        mirrorStoreTarget,
        policyModelsTarget,
        kitTarget,
        policyCanvasAlgorithmsTarget,
        intentsTarget,
        intentsExtensionTarget,
        widgetsExtensionTarget,
        cloudKitTarget,
        macRelayTarget,
        watchWidgetsTarget,
        watchAppTarget,
        mobileAppTarget,
        mobileWidgetsTarget,
        policyCanvasTarget,
        uiPreviewableTarget,
        previewHostTarget,
        policyCanvasLabHostTarget,
        monitorAppTarget,
        externalDaemonAppTarget,
        uiTestHostTarget,
        isolatedAppTarget,
        appTestsTarget,
        kitTestsTarget,
        policyCanvasTestsTarget,
        policyCanvasAlgorithmTestsTarget,
        intentsTestsTarget,
        cloudKitTestsTarget,
        coreTestsTarget,
        mirrorStoreTestsTarget,
        cryptoTestsTarget,
        cloudMirrorTestsTarget,
        macRelayTestsTarget,
        uiTestsTarget,
        agentsE2ETarget
    ],
    schemes: [
        monitorScheme,
        kitTestsScheme,
        policyCanvasTestsScheme,
        policyCanvasAlgorithmTestsScheme,
        intentsTestsScheme,
        cloudKitTestsScheme,
        cryptoScheme,
        cryptoTestsScheme,
        cloudMirrorTestsScheme,
        macRelayTestsScheme,
        mobileFoundationTestsScheme,
        appTestsScheme,
        externalDaemonScheme,
        uiTestHostScheme,
        isolatedScheme,
        agentsE2EScheme,
        watchAppScheme,
        mobileAppScheme,
        uiPreviewableScheme,
        policyCanvasLabHostScheme,
        uiPreviewsScheme
    ]
)
