import ProjectDescription
import ProjectDescriptionHelpers

private let macOSDestinations: Destinations = [.mac]
private let macOSDeploymentTargets: DeploymentTargets = .macOS("26.0")
private let xcodeVisibleAppEntitlementsPath: Path = "HarnessMonitorBase.entitlements"
private let xcodeVisibleExternalDaemonEntitlementsPath: Path =
    "HarnessMonitorExternalDaemon.entitlements"
private let generatedAppEntitlements: SettingValue =
    "$(PROJECT_TEMP_DIR)/GeneratedAppEntitlements/$(TARGET_NAME).codesign.entitlements"

private let monitorAppSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitor/**/*.swift", excluding: ["Sources/HarnessMonitor/Features/**"])
] + FeatureFlags.appAdditionalSourceGlobs(target: "HarnessMonitor"))

private let uiPreviewableSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorUIPreviewable/**/*.swift", excluding: ["Sources/HarnessMonitorUIPreviewable/Features/**"])
] + FeatureFlags.uiPreviewableAdditionalSourceGlobs())

private let kitSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorKit/**/*.swift", excluding: ["Sources/HarnessMonitorKit/Features/**"])
] + FeatureFlags.kitAdditionalSourceGlobs())

private let kitDependencies: [TargetDependency] = {
    var deps: [TargetDependency] = [
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
        .external(name: "HarnessMonitorRegistry")
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

private let uiPreviewableTarget: Target = {
    var deps: [TargetDependency] = [
        .target(name: "HarnessMonitorKit"),
        .sdk(name: "SwiftData", type: .framework)
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

private let monitorAppDependencies: [TargetDependency] = {
    var deps: [TargetDependency] = [
        .target(name: "HarnessMonitorKit"),
        .target(name: "HarnessMonitorIntents"),
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
    monitorAppDependencies + [.target(name: "HarnessMonitorIntentsExtension")]

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
// provisioning profile covers both variants and so user defaults / app-group
// containers stay shared. The two products live side-by-side in DerivedData
// thanks to their distinct PRODUCT_NAME values, and `HARNESS_MONITOR_EXTERNAL_DAEMON=1`
// is what actually selects external-daemon runtime behavior at launch.
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
        "REGISTER_APP_GROUPS": "YES",
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

private let appTestsEnv: [String: EnvironmentVariable] = [
    "HARNESS_DAEMON_DATA_HOME": .environmentVariable(value: "/tmp/harness-monitor-tests", isEnabled: true),
    "HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE": .environmentVariable(value: "1", isEnabled: true),
    "HARNESS_MONITOR_LAUNCH_MODE": .environmentVariable(value: "preview", isEnabled: true)
]

private let appTestsTarget: Target = .target(
    name: "HarnessMonitorAppTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.app-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: ["Tests/HarnessMonitorAppTests/**/*.swift"],
    dependencies: [.target(name: "HarnessMonitor")],
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
    .glob("Tests/HarnessMonitorKitTests/**/*.swift", excluding: ["Tests/HarnessMonitorKitTests/Features/**"])
] + FeatureFlags.kitTestsAdditionalSourceGlobs())

private let kitTestsTarget: Target = .target(
    name: "HarnessMonitorKitTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.kit-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: kitTestsSources,
    dependencies: [
        .target(name: "HarnessMonitorKit"),
        .target(name: "HarnessMonitorUIPreviewable")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.kit-tests",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
    ]),
    metadata: .metadata(tags: ["tag:feature:monitor", "tag:layer:test"])
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
        kitTarget,
        intentsTarget,
        intentsExtensionTarget,
        uiPreviewableTarget,
        previewHostTarget,
        monitorAppTarget,
        externalDaemonAppTarget,
        uiTestHostTarget,
        appTestsTarget,
        kitTestsTarget,
        intentsTestsTarget,
        uiTestsTarget,
        agentsE2ETarget
    ],
    schemes: [
        monitorScheme,
        kitTestsScheme,
        intentsTestsScheme,
        appTestsScheme,
        externalDaemonScheme,
        uiTestHostScheme,
        agentsE2EScheme,
        uiPreviewableScheme,
        uiPreviewsScheme
    ]
)
