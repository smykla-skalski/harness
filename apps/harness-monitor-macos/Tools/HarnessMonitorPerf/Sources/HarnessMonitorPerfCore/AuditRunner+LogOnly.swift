import Foundation

extension AuditRunner {
    static func runLogOnlyScenarios(
        scenarios: [String],
        runDir: URL,
        staged: HostStager.Result,
        defaultEnv: [String: String],
        checkoutRoot: URL,
        appRoot: URL,
        gitCommit: String,
        gitDirty: String,
        workspaceFingerprint: String,
        buildStartedAtUTC: String,
        arch: String,
        hostAppPath: URL,
        shippingAppPath: URL,
        buildShipping: Bool,
        skipDaemonBundle: Bool,
        daemonCargoTargetDir: URL,
        label: String,
        runID: String,
        createdAtUTC: String,
        debugRetention: Bool
    ) throws -> RunOutcome {
        var captureRecords: [ManifestBuilder.CaptureRecord] = []
        var reports: [LogProbeRecorder.Report] = []
        for scenario in scenarios {
            let capture = try logProbeOne(
                scenario: scenario,
                runDir: runDir,
                staged: staged,
                defaultEnv: defaultEnv,
                checkoutRoot: checkoutRoot,
                appRoot: appRoot,
                gitCommit: gitCommit,
                workspaceFingerprint: workspaceFingerprint
            )
            captureRecords.append(capture.record)
            reports.append(capture.report)
        }

        cleanupHostProcesses()
        try assertSourceUnchanged(
            checkpoint: "before writing log-only summary",
            checkoutRoot: checkoutRoot,
            appRoot: appRoot,
            gitCommit: gitCommit,
            workspaceFingerprint: workspaceFingerprint
        )

        let manifest = try buildManifest(
            label: label, runID: runID, createdAtUTC: createdAtUTC,
            gitCommit: gitCommit, gitDirty: gitDirty,
            workspaceFingerprint: workspaceFingerprint,
            buildStartedAtUTC: buildStartedAtUTC,
            arch: arch,
            project: appRoot.appendingPathComponent("HarnessMonitor.xcodeproj"),
            hostAppPath: hostAppPath, shippingAppPath: shippingAppPath,
            staged: staged,
            buildShipping: buildShipping,
            skipDaemonBundle: skipDaemonBundle,
            daemonCargoTargetDir: daemonCargoTargetDir,
            captureRecords: captureRecords,
            selectedScenarios: scenarios,
            defaultEnvironment: defaultEnv
        )
        let manifestPath = runDir.appendingPathComponent("manifest.json")
        try ManifestBuilder.write(manifest, to: manifestPath)

        let summaryPath = runDir.appendingPathComponent("log-only-summary.json")
        try LogProbeRecorder.writeSummary(
            .init(mode: "log-only", captures: reports),
            to: summaryPath
        )
        if debugRetention {
            try writeDebugRetentionManifest(to: runDir, keepTraces: false)
        }
        try RunPruner.prune(
            runDir: runDir,
            keepTraces: false,
            debugRetention: debugRetention
        )
        return RunOutcome(runDir: runDir, summaryPath: summaryPath, comparisonPath: nil)
    }

    private static func logProbeOne(
        scenario: String,
        runDir: URL,
        staged: HostStager.Result,
        defaultEnv: [String: String],
        checkoutRoot: URL,
        appRoot: URL,
        gitCommit: String,
        workspaceFingerprint: String
    ) throws -> LogProbeRecorder.Capture {
        let dataHome = try auditDaemonDataHome(
            runDir: runDir,
            templateSlug: LogProbeRecorder.templateSlug,
            scenario: scenario,
            defaultEnvironment: defaultEnv,
            processIsLive: externalDaemonProcessIsLive
        )
        let appTraceRelpath = AuditArtifactPaths.appTraceRelpath(
            scenario: scenario,
            templateSlug: LogProbeRecorder.templateSlug
        )
        let logRoot = runDir.appendingPathComponent("logs", isDirectory: true)
        let logURL = logRoot.appendingPathComponent("log-only-\(scenario).log")
        let stdoutURL = logRoot.appendingPathComponent("log-only-\(scenario).stdout.log")
        let stderrURL = logRoot.appendingPathComponent("log-only-\(scenario).stderr.log")

        var env = defaultEnv
        env["HARNESS_DAEMON_DATA_HOME"] = dataHome.launchDataHome.path
        env["HARNESS_MONITOR_PERF_SCENARIO"] = scenario
        env["HARNESS_MONITOR_PREVIEW_SCENARIO"] = ScenarioCatalog.previewScenario(for: scenario)
        env[AuditArtifactPaths.perfArtifactsDirectoryKey] = AuditArtifactPaths
            .appTraceDirectory(
                runDir: runDir,
                scenario: scenario,
                templateSlug: LogProbeRecorder.templateSlug
            )
            .path

        try assertSourceUnchanged(
            checkpoint: "before log-only launch / \(scenario)",
            checkoutRoot: checkoutRoot,
            appRoot: appRoot,
            gitCommit: gitCommit,
            workspaceFingerprint: workspaceFingerprint
        )

        let inputs = LogProbeRecorder.ScenarioInputs(
            scenario: scenario,
            previewScenario: ScenarioCatalog.previewScenario(for: scenario),
            durationSeconds: ScenarioCatalog.durationSeconds(for: scenario),
            hostAppPath: staged.stagedAppPath,
            hostBinaryPath: staged.stagedBinaryPath,
            launchArguments: persistenceArguments,
            environment: env,
            logURL: logURL,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            daemonDataHome: dataHome.launchDataHome,
            daemonDataHomeProbe: dataHome.probeDataHome,
            runDir: runDir,
            appTraceRelpath: appTraceRelpath
        )
        let capture = try LogProbeRecorder.record(inputs)
        cleanupHostProcesses()
        try assertSourceUnchanged(
            checkpoint: "after log-only launch / \(scenario)",
            checkoutRoot: checkoutRoot,
            appRoot: appRoot,
            gitCommit: gitCommit,
            workspaceFingerprint: workspaceFingerprint
        )
        return capture
    }
}
