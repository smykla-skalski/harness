import Foundation

/// Orchestrates the full Instruments audit pipeline end-to-end. Direct port of
/// run-instruments-audit.sh; delegates to BuildOrchestrator, HostStager, TraceRecorder,
/// ManifestBuilder, ExtractorOrchestrator, BudgetEnforcer, Comparator, RunPruner.
public enum AuditRunner {
    public static let shippingScheme = "HarnessMonitor"
    public static let hostScheme = "HarnessMonitorUITestHost"
    public static let hostBundleID = "io.harnessmonitor.app.ui-testing"
    public static let stagedHostSuffix = ".audit"
    public static let persistenceArguments = ["-ApplePersistenceIgnoreState", "YES"]
    public static let daemonDataHomeOverrideEnvironmentKey =
        "HARNESS_MONITOR_AUDIT_DAEMON_DATA_HOME"
    public static let launchMetricsPathEnvironmentKey =
        "HARNESS_MONITOR_PERF_LAUNCH_METRICS_PATH"
    public static let passThroughEnvironmentKeys: Set<String> = [
        "HARNESS_MONITOR_EXTERNAL_DAEMON",
        "HARNESS_MONITOR_LAUNCH_MODE",
        "HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE",
        "HARNESS_MONITOR_MENU_BAR_STATE_COLORS_OVERRIDE",
        "HARNESS_MONITOR_PERF_DISABLE_SEARCH_HOST",
        "HARNESS_MONITOR_PERF_DISABLE_SEARCH_SUGGESTIONS",
        "HARNESS_MONITOR_PERF_ENABLE_SCENE_WRITES",
        "HARNESS_MONITOR_PERF_STATIC_DETAIL",
        "HARNESS_MONITOR_SESSION_SHORTCUT_OVERLAYS_OVERRIDE",
        "HARNESS_MONITOR_SESSION_TITLE_BLUR_OVERRIDE",
    ]

    public static let baseEnvironment: [String: String] = [
        "HARNESS_MONITOR_UI_TESTS": "1",
        "HARNESS_MONITOR_UI_ACCESSIBILITY_MARKERS": "0",
        "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
        "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH": "1640",
        "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT": "980",
        "HARNESS_MONITOR_PERF_HIDE_DOCK_ICON": "1",
    ]

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public struct Inputs {
        public var label: String
        public var compareTo: URL?
        public var scenarioSelection: String
        public var keepTraces: Bool
        public var debugRetention: Bool
        public var checkoutRoot: URL
        public var commonRepoRoot: URL
        public var appRoot: URL
        public var xcodebuildRunner: URL
        public var derivedDataPath: URL
        public var runsRoot: URL
        public var stagedHostStageRoot: URL
        public var auditDaemonCargoTargetDir: URL
        public var arch: String
        public var destination: String
        public var skipBuild: Bool
        public var skipDaemonBundle: Bool
        public var forceClean: Bool
        public var buildShipping: Bool
        public var logOnly: Bool
        public var enforceBudgets: Bool
        public var environmentOverrides: [String: String]

        public init(
            label: String, compareTo: URL?, scenarioSelection: String, keepTraces: Bool,
            debugRetention: Bool,
            checkoutRoot: URL, commonRepoRoot: URL, appRoot: URL,
            xcodebuildRunner: URL, derivedDataPath: URL,
            runsRoot: URL, stagedHostStageRoot: URL, auditDaemonCargoTargetDir: URL,
            arch: String, destination: String,
            skipBuild: Bool, skipDaemonBundle: Bool, forceClean: Bool, buildShipping: Bool,
            logOnly: Bool, enforceBudgets: Bool = true,
            environmentOverrides: [String: String] = [:]
        ) {
            self.label = label
            self.compareTo = compareTo
            self.scenarioSelection = scenarioSelection
            self.keepTraces = keepTraces
            self.debugRetention = debugRetention
            self.checkoutRoot = checkoutRoot
            self.commonRepoRoot = commonRepoRoot
            self.appRoot = appRoot
            self.xcodebuildRunner = xcodebuildRunner
            self.derivedDataPath = derivedDataPath
            self.runsRoot = runsRoot
            self.stagedHostStageRoot = stagedHostStageRoot
            self.auditDaemonCargoTargetDir = auditDaemonCargoTargetDir
            self.arch = arch
            self.destination = destination
            self.skipBuild = skipBuild
            self.skipDaemonBundle = skipDaemonBundle
            self.forceClean = forceClean
            self.buildShipping = buildShipping
            self.logOnly = logOnly
            self.enforceBudgets = enforceBudgets
            self.environmentOverrides = environmentOverrides
        }
    }

    public struct RunOutcome {
        public var runDir: URL
        public var summaryPath: URL
        public var comparisonPath: URL?
    }

    public struct AuditDaemonDataHome: Equatable {
        public var launchDataHome: URL
        public var probeDataHome: URL
        public var mirroredManifest: Bool

        public init(launchDataHome: URL, probeDataHome: URL, mirroredManifest: Bool) {
            self.launchDataHome = launchDataHome
            self.probeDataHome = probeDataHome
            self.mirroredManifest = mirroredManifest
        }
    }

    public static func run(_ inputs: Inputs) throws -> RunOutcome {
        let effectiveKeepTraces = inputs.keepTraces || inputs.debugRetention
        let scenarios = try ScenarioCatalog.resolve(inputs.scenarioSelection)
        let gitCommit = try gitRevParseHead(inputs.checkoutRoot)
        let gitDirty = try gitDirtyFlag(inputs.checkoutRoot)
        let workspaceFingerprint = try WorkspaceFingerprint.compute(
            variant: .audit,
            projectDir: inputs.appRoot
        )
        let defaultRuntimeEnv = defaultEnvironment()
            .merging(inputs.environmentOverrides) { _, override in override }
        let allowExternalDaemonAudit = shouldAllowExternalDaemonAudit(
            defaultEnvironment: defaultRuntimeEnv
        )

        let timestamp = utcCompactTimestamp()
        let labelSlug = inputs.label.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression
        )
        let runID = "\(timestamp)-\(labelSlug)"
        let runDir = inputs.runsRoot.appendingPathComponent(runID, isDirectory: true)
        let tracesRoot = runDir.appendingPathComponent("traces", isDirectory: true)
        let xctraceTempRoot = runDir.appendingPathComponent("xctrace-tmp", isDirectory: true)
        let lockDir = inputs.runsRoot.appendingPathComponent(".audit.lock", isDirectory: true)

        try FileManager.default.createDirectory(at: inputs.runsRoot, withIntermediateDirectories: true)
        let lockInfo = AuditLock.Info(
            runID: runID, label: inputs.label,
            startedAtUTC: timestamp, runDir: runDir.path,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        try AuditLock.acquire(at: lockDir, info: lockInfo)
        defer { AuditLock.release(at: lockDir) }
        defer { cleanupHostProcesses() }

        try FileManager.default.createDirectory(at: tracesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xctraceTempRoot, withIntermediateDirectories: true)

        let hostAppPath = inputs.derivedDataPath
            .appendingPathComponent("Build/Products/Release/Harness Monitor UI Testing.app")
        let hostBinaryPath = hostAppPath
            .appendingPathComponent("Contents/MacOS/Harness Monitor UI Testing")
        let shippingAppPath = inputs.derivedDataPath
            .appendingPathComponent("Build/Products/Release/Harness Monitor.app")
        let shippingBinaryPath = shippingAppPath
            .appendingPathComponent("Contents/MacOS/Harness Monitor")

        cleanupHostProcesses()

        let canReuseReleaseProducts =
            !allowExternalDaemonAudit
            && !inputs.forceClean
            && BuildOrchestrator.releaseProductsCurrent(
                hostAppPath: hostAppPath,
                hostBinaryPath: hostBinaryPath,
                shippingAppPath: shippingAppPath,
                shippingBinaryPath: shippingBinaryPath,
                buildShipping: inputs.buildShipping,
                gitCommit: gitCommit,
                gitDirty: gitDirty,
                workspaceFingerprint: workspaceFingerprint
            )

        var buildStartedAtUTC = ""
        if inputs.skipBuild {
            // honor existing bundle - read started_at from plist below
        } else if canReuseReleaseProducts {
            buildStartedAtUTC = BuildOrchestrator.bundleProvenanceValue(
                bundle: hostAppPath, key: BuildOrchestrator.buildStartedAtUTCKey
            )
            if buildStartedAtUTC.isEmpty {
                buildStartedAtUTC = (try? BuildOrchestrator.binaryMtimeUTC(hostBinaryPath)) ?? ""
            }
        } else {
            buildStartedAtUTC = utcExtendedTimestamp()
            BuildOrchestrator.purgeReleaseProducts(hostAppPath: hostAppPath, shippingAppPath: shippingAppPath)
            try BuildOrchestrator.buildReleaseTargets(.init(
                xcodebuildRunner: inputs.xcodebuildRunner,
                workspacePath: inputs.appRoot.appendingPathComponent("HarnessMonitor.xcworkspace"),
                derivedDataPath: inputs.derivedDataPath,
                destination: inputs.destination,
                arch: inputs.arch,
                shippingScheme: shippingScheme, hostScheme: hostScheme,
                buildShipping: inputs.buildShipping,
                forceClean: inputs.forceClean,
                skipDaemonBundle: inputs.skipDaemonBundle,
                daemonCargoTargetDir: inputs.auditDaemonCargoTargetDir,
                gitCommit: gitCommit, gitDirty: gitDirty,
                workspaceFingerprint: workspaceFingerprint,
                buildStartedAtUTC: buildStartedAtUTC,
                allowExternalDaemonAudit: allowExternalDaemonAudit
            ))
        }

        try assertSourceUnchanged(
            checkpoint: "Release build", checkoutRoot: inputs.checkoutRoot,
            appRoot: inputs.appRoot, gitCommit: gitCommit,
            workspaceFingerprint: workspaceFingerprint
        )

        if buildStartedAtUTC.isEmpty {
            buildStartedAtUTC = (try? BuildOrchestrator.binaryMtimeUTC(hostBinaryPath)) ?? ""
        }

        guard FileManager.default.isExecutableFile(atPath: hostBinaryPath.path) else {
            throw Failure(message: "Expected UI-test host binary not found at \(hostBinaryPath.path)")
        }

        try validateProvenance(
            bundle: hostAppPath, label: "Host",
            gitCommit: gitCommit, gitDirty: gitDirty,
            workspaceFingerprint: workspaceFingerprint, allowMismatch: inputs.skipBuild
        )
        if inputs.buildShipping {
            try validateProvenance(
                bundle: shippingAppPath, label: "Shipping",
                gitCommit: gitCommit, gitDirty: gitDirty,
                workspaceFingerprint: workspaceFingerprint, allowMismatch: inputs.skipBuild
            )
        }

        try HostStager.purgeLegacyLaunchHosts(in: inputs.runsRoot)
        let staged = try HostStager.stage(
            hostAppPath: hostAppPath,
            stageRoot: inputs.stagedHostStageRoot,
            stagedBundleID: hostBundleID + stagedHostSuffix
        )
        guard FileManager.default.isExecutableFile(atPath: staged.stagedBinaryPath.path) else {
            throw Failure(message: "Expected staged UI-test host binary not found at \(staged.stagedBinaryPath.path)")
        }

        let capturesTSV = runDir.appendingPathComponent("captures.tsv")
        FileManager.default.createFile(atPath: capturesTSV.path, contents: nil)

        let baseAuditEnv: [String: String] = [
            "HARNESS_MONITOR_AUDIT_GIT_COMMIT": gitCommit,
            "HARNESS_MONITOR_AUDIT_GIT_DIRTY": gitDirty,
            "HARNESS_MONITOR_AUDIT_RUN_ID": runID,
            "HARNESS_MONITOR_AUDIT_LABEL": inputs.label,
            "HARNESS_MONITOR_AUDIT_WORKSPACE_FINGERPRINT": workspaceFingerprint,
            "HARNESS_MONITOR_AUDIT_BUILD_STARTED_AT_UTC": buildStartedAtUTC,
        ]
        let combinedDefaultEnv = defaultRuntimeEnv
            .merging(baseAuditEnv) { _, audit in audit }

        if inputs.logOnly {
            return try runLogOnlyScenarios(
                scenarios: scenarios,
                runDir: runDir,
                staged: staged,
                defaultEnv: combinedDefaultEnv,
                checkoutRoot: inputs.checkoutRoot,
                appRoot: inputs.appRoot,
                gitCommit: gitCommit,
                gitDirty: gitDirty,
                workspaceFingerprint: workspaceFingerprint,
                buildStartedAtUTC: buildStartedAtUTC,
                arch: inputs.arch,
                hostAppPath: hostAppPath,
                shippingAppPath: shippingAppPath,
                buildShipping: inputs.buildShipping,
                skipDaemonBundle: inputs.skipDaemonBundle,
                daemonCargoTargetDir: inputs.auditDaemonCargoTargetDir,
                label: inputs.label,
                runID: runID,
                createdAtUTC: timestamp,
                debugRetention: inputs.debugRetention
            )
        }

        var captureRecords: [ManifestBuilder.CaptureRecord] = []
        for scenario in scenarios {
            if ScenarioCatalog.swiftUI.contains(scenario) {
                let capture = try recordOne(
                    template: "SwiftUI", scenario: scenario, runDir: runDir,
                    tracesRoot: tracesRoot, xctraceTempRoot: xctraceTempRoot,
                    staged: staged, defaultEnv: combinedDefaultEnv,
                    checkoutRoot: inputs.checkoutRoot, appRoot: inputs.appRoot,
                    gitCommit: gitCommit, workspaceFingerprint: workspaceFingerprint
                )
                captureRecords.append(capture.record)
                try appendCaptureTSV(capturesTSV, capture: capture)
            }
            if ScenarioCatalog.allocations.contains(scenario) {
                let capture = try recordOne(
                    template: "Allocations", scenario: scenario, runDir: runDir,
                    tracesRoot: tracesRoot, xctraceTempRoot: xctraceTempRoot,
                    staged: staged, defaultEnv: combinedDefaultEnv,
                    checkoutRoot: inputs.checkoutRoot, appRoot: inputs.appRoot,
                    gitCommit: gitCommit, workspaceFingerprint: workspaceFingerprint
                )
                captureRecords.append(capture.record)
                try appendCaptureTSV(capturesTSV, capture: capture)
            }
        }

        cleanupHostProcesses()
        try assertSourceUnchanged(
            checkpoint: "before writing summary", checkoutRoot: inputs.checkoutRoot,
            appRoot: inputs.appRoot, gitCommit: gitCommit,
            workspaceFingerprint: workspaceFingerprint
        )

        let manifest = try buildManifest(
            label: inputs.label, runID: runID, createdAtUTC: timestamp,
            gitCommit: gitCommit, gitDirty: gitDirty,
            workspaceFingerprint: workspaceFingerprint,
            buildStartedAtUTC: buildStartedAtUTC,
            arch: inputs.arch,
            project: inputs.appRoot.appendingPathComponent("HarnessMonitor.xcodeproj"),
            hostAppPath: hostAppPath, shippingAppPath: shippingAppPath,
            staged: staged,
            buildShipping: inputs.buildShipping,
            skipDaemonBundle: inputs.skipDaemonBundle,
            daemonCargoTargetDir: inputs.auditDaemonCargoTargetDir,
            captureRecords: captureRecords,
            selectedScenarios: scenarios,
            defaultEnvironment: defaultRuntimeEnv
        )
        let manifestPath = runDir.appendingPathComponent("manifest.json")
        try ManifestBuilder.write(manifest, to: manifestPath)

        let exporter = ExtractorOrchestrator.ProcessXctrace(
            command: "/usr/bin/xcrun",
            arguments: ["xctrace"],
            tempRoot: xctraceTempRoot
        )
        _ = try ExtractorOrchestrator.extract(
            runDir: runDir,
            exporter: exporter,
            debugExportsRoot: inputs.debugRetention
                ? runDir.appendingPathComponent("exports", isDirectory: true)
                : nil
        )
        if inputs.debugRetention {
            try writeDebugRetentionManifest(
                to: runDir,
                keepTraces: effectiveKeepTraces
            )
        }
        let summaryPath = runDir.appendingPathComponent("summary.json")
        let summaryData = try Data(contentsOf: summaryPath)
        if inputs.enforceBudgets {
            try BudgetEnforcer.enforce(summaryJSON: summaryData)
        }

        var comparisonPath: URL?
        if let baseline = inputs.compareTo {
            _ = try Comparator.compare(.init(current: runDir, baseline: baseline, outputDir: runDir))
            comparisonPath = runDir.appendingPathComponent("comparison.md")
        }

        if !effectiveKeepTraces {
            try? FileManager.default.removeItem(at: tracesRoot)
        }
        try RunPruner.prune(
            runDir: runDir,
            keepTraces: effectiveKeepTraces,
            debugRetention: inputs.debugRetention
        )

        return RunOutcome(runDir: runDir, summaryPath: summaryPath, comparisonPath: comparisonPath)
    }

    // MARK: - Internals

    static func writeDebugRetentionManifest(
        to runDir: URL,
        keepTraces: Bool
    ) throws {
        let url = runDir.appendingPathComponent("debug-retention.json")
        let payload: [String: Any] = [
            "enabled": true,
            "keeps_traces": keepTraces,
            "exports_directory": "exports",
            "launch_metrics_directory": "launch-metrics",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
