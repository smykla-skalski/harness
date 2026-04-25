import ProjectDescription
import ProjectDescriptionHelpers

private let macOSDestinations: Destinations = [.mac]
private let macOSDeploymentTargets: DeploymentTargets = .macOS("26.0")

private let monitorAppSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitor/**/*.swift", excluding: ["Sources/HarnessMonitor/Features/**"])
] + FeatureFlags.appAdditionalSourceGlobs(target: "HarnessMonitor"))

private let uiPreviewableSources: SourceFilesList = SourceFilesList(globs: [
    .glob("Sources/HarnessMonitorUIPreviewable/**/*.swift", excluding: ["Sources/HarnessMonitorUIPreviewable/Features/**"])
] + FeatureFlags.uiPreviewableAdditionalSourceGlobs())

private let kitTarget: Target = .target(
    name: "HarnessMonitorKit",
    destinations: macOSDestinations,
    product: .framework,
    bundleId: "io.harnessmonitor.kit",
    deploymentTargets: macOSDeploymentTargets,
    sources: ["Sources/HarnessMonitorKit/**/*.swift"],
    dependencies: [
        .sdk(name: "AppKit", type: .framework),
        .sdk(name: "ApplicationServices", type: .framework),
        .sdk(name: "AVFAudio", type: .framework),
        .sdk(name: "CoreMedia", type: .framework),
        .sdk(name: "SwiftData", type: .framework),
        .sdk(name: "Speech", type: .framework),
        .sdk(name: "IOKit", type: .framework),
        .sdk(name: "ServiceManagement", type: .framework),
        .sdk(name: "UserNotifications", type: .framework),
        .external(name: "OpenTelemetryApi"),
        .external(name: "OpenTelemetryConcurrency"),
        .external(name: "OpenTelemetrySdk"),
        .external(name: "PersistenceExporter"),
        .external(name: "OpenTelemetryProtocolExporter"),
        .external(name: "OpenTelemetryProtocolExporterHTTP"),
        .external(name: "GRPC"),
        .external(name: "HarnessMonitorRegistry")
    ],
    settings: BuildSettings.frameworkSettings(bundleId: "io.harnessmonitor.kit")
)

private let uiPreviewableTarget: Target = {
    var deps: [TargetDependency] = [
        .target(name: "HarnessMonitorKit"),
        .external(name: "Textual"),
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
        dependencies: deps,
        settings: .settings(
            base: [
                "CODE_SIGN_STYLE": "Automatic",
                "CODE_SIGNING_ALLOWED": "YES",
                "DEVELOPMENT_TEAM": "Q498EB36N4",
                "ENABLE_MODULE_VERIFIER": "YES",
                "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
                "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu17 gnu++20",
                "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.ui.previewable",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": FeatureFlags.compilationConditionSetting()
            ],
            configurations: [
                .debug(name: "Debug"),
                .debug(name: "Preview", settings: [
                    "COMPILER_INDEX_STORE_ENABLE": "NO",
                    "ENABLE_MODULE_VERIFIER": "NO",
                    "ONLY_ACTIVE_ARCH": "YES",
                    "SWIFT_ENABLE_EAGER_LINKING": "NO"
                ]),
                .release(name: "Release")
            ]
        )
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
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGNING_ALLOWED": "YES",
            "DEVELOPMENT_TEAM": "Q498EB36N4",
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
                "ENABLE_MODULE_VERIFIER": "NO",
                "ONLY_ACTIVE_ARCH": "YES",
                "SWIFT_ENABLE_EAGER_LINKING": "NO"
            ]),
            .release(name: "Release")
        ]
    )
)

private let monitorAppDependencies: [TargetDependency] = {
    var deps: [TargetDependency] = [
        .target(name: "HarnessMonitorKit"),
        .target(name: "HarnessMonitorUIPreviewable")
    ]
    deps.append(contentsOf: FeatureFlags.appAdditionalDependencies())
    return deps
}()

private let monitorAppSettings: Settings = .settings(
    base: [
        "CODE_SIGN_ENTITLEMENTS": "HarnessMonitor.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": "Q498EB36N4",
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "ENABLE_INCOMING_NETWORK_CONNECTIONS": "NO",
        "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/HarnessMonitor-Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "$(HARNESS_MONITOR_APP_BUNDLE_ID)",
        "PRODUCT_NAME": "Harness Monitor",
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
    resources: ["Resources/PrivacyInfo.xcprivacy"],
    entitlements: .file(path: "HarnessMonitor.entitlements"),
    scripts: [
        BuildPhases.bundleDaemonAgent(),
        BuildPhases.clearGatekeeperMetadata(variant: .monitorApp)
    ],
    dependencies: monitorAppDependencies,
    settings: monitorAppSettings
)

private let uiTestHostSettings: Settings = .settings(
    base: [
        "CODE_SIGN_ENTITLEMENTS": "HarnessMonitorUITestHost.entitlements",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": "Q498EB36N4",
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "ENABLE_INCOMING_NETWORK_CONNECTIONS": "NO",
        "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Resources/HarnessMonitor-Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.app.ui-testing",
        "PRODUCT_NAME": "Harness Monitor UI Testing",
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
    resources: ["Resources/PrivacyInfo.xcprivacy"],
    entitlements: .file(path: "HarnessMonitorUITestHost.entitlements"),
    scripts: [
        BuildPhases.bundleDaemonAgent(),
        BuildPhases.clearGatekeeperMetadata(variant: .uiTestHost)
    ],
    dependencies: monitorAppDependencies,
    settings: uiTestHostSettings
)

private let kitTestsTarget: Target = .target(
    name: "HarnessMonitorKitTests",
    destinations: macOSDestinations,
    product: .unitTests,
    bundleId: "io.harnessmonitor.kit-tests",
    deploymentTargets: macOSDeploymentTargets,
    sources: ["Tests/HarnessMonitorKitTests/**/*.swift"],
    dependencies: [
        .target(name: "HarnessMonitorKit"),
        .target(name: "HarnessMonitorUIPreviewable")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": "Q498EB36N4",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.kit-tests"
    ])
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
    scripts: [BuildPhases.stripTestBundleXattrs()],
    dependencies: [
        .target(name: "HarnessMonitorUITestHost")
    ],
    settings: .settings(base: [
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": "Q498EB36N4",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.ui-tests",
        "TEST_TARGET_NAME": "HarnessMonitorUITestHost"
    ])
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
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": "Q498EB36N4",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.harnessmonitor.agents-e2e-tests",
        "TEST_TARGET_NAME": "HarnessMonitorUITestHost"
    ])
)

private let monitorRunEnv: [String: EnvironmentVariable] = [
    "HARNESS_OTEL_EXPORT": .environmentVariable(value: "1", isEnabled: true),
    "OTEL_EXPORTER_OTLP_ENDPOINT": .environmentVariable(value: "http://127.0.0.1:4317", isEnabled: true)
]

private let monitorTestEnv: [String: EnvironmentVariable] = [
    "HARNESS_DAEMON_DATA_HOME": .environmentVariable(value: "/tmp/harness-monitor-tests", isEnabled: true)
]

private let externalDaemonRunEnv: [String: EnvironmentVariable] = [
    "HARNESS_OTEL_EXPORT": .environmentVariable(value: "1", isEnabled: true),
    "OTEL_EXPORTER_OTLP_ENDPOINT": .environmentVariable(value: "http://127.0.0.1:4317", isEnabled: true),
    "HARNESS_MONITOR_EXTERNAL_DAEMON": .environmentVariable(value: "1", isEnabled: true),
    "HARNESS_BOOTSTRAP_TIMEOUT_SECONDS": .environmentVariable(value: "60", isEnabled: true)
]

private let monitorScheme: Scheme = .scheme(
    name: "HarnessMonitor",
    shared: true,
    buildAction: .buildAction(targets: [
        .target("HarnessMonitor"),
        .target("HarnessMonitorKit"),
        .target("HarnessMonitorUIPreviewable")
    ]),
    testAction: .targets(
        [
            .testableTarget(target: .target("HarnessMonitorKitTests")),
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

private let externalDaemonScheme: Scheme = .scheme(
    name: "HarnessMonitor (External Daemon)",
    shared: true,
    buildAction: .buildAction(targets: [
        .target("HarnessMonitor"),
        .target("HarnessMonitorKit"),
        .target("HarnessMonitorUIPreviewable")
    ]),
    runAction: .runAction(
        configuration: "Debug",
        executable: .target("HarnessMonitor"),
        arguments: Arguments.arguments(environmentVariables: externalDaemonRunEnv)
    )
)

private let agentsE2EScheme: Scheme = .scheme(
    name: "HarnessMonitorAgentsE2E",
    shared: true,
    buildAction: .buildAction(targets: [
        .target("HarnessMonitor"),
        .target("HarnessMonitorKit"),
        .target("HarnessMonitorUIPreviewable")
    ]),
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
    testAction: .targets([], configuration: "Preview"),
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
    testAction: .targets([], configuration: "Preview"),
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
        uiPreviewableTarget,
        previewHostTarget,
        monitorAppTarget,
        uiTestHostTarget,
        kitTestsTarget,
        uiTestsTarget,
        agentsE2ETarget
    ],
    schemes: [
        monitorScheme,
        kitTestsScheme,
        externalDaemonScheme,
        agentsE2EScheme,
        uiPreviewableScheme,
        uiPreviewsScheme
    ]
)
