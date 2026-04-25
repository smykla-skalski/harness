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

    public static let baseEnvironment: [String: String] = [
        "HARNESS_MONITOR_UI_TESTS": "1",
        "HARNESS_MONITOR_UI_ACCESSIBILITY_MARKERS": "0",
        "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
        "HARNESS_MONITOR_LAUNCH_MODE": "preview",
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

        public init(
            label: String, compareTo: URL?, scenarioSelection: String, keepTraces: Bool,
            checkoutRoot: URL, commonRepoRoot: URL, appRoot: URL,
            xcodebuildRunner: URL, derivedDataPath: URL,
            runsRoot: URL, stagedHostStageRoot: URL, auditDaemonCargoTargetDir: URL,
            arch: String, destination: String,
            skipBuild: Bool, skipDaemonBundle: Bool, forceClean: Bool, buildShipping: Bool
        ) {
            self.label = label
            self.compareTo = compareTo
            self.scenarioSelection = scenarioSelection
            self.keepTraces = keepTraces
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
        }
    }

    public struct RunOutcome {
        public var runDir: URL
        public var summaryPath: URL
        public var comparisonPath: URL?
    }

    public static func run(_ inputs: Inputs) throws -> RunOutcome {
        let scenarios = try ScenarioCatalog.resolve(inputs.scenarioSelection)
        let gitCommit = try gitRevParseHead(inputs.checkoutRoot)
        let gitDirty = try gitDirtyFlag(inputs.checkoutRoot)
        let workspaceFingerprint = try WorkspaceFingerprint.compute(variant: .audit, projectDir: inputs.appRoot)

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

        var buildStartedAtUTC = ""
        if inputs.skipBuild {
            // honor existing bundle - read started_at from plist below
        } else if !inputs.forceClean && BuildOrchestrator.releaseProductsCurrent(
            hostAppPath: hostAppPath, hostBinaryPath: hostBinaryPath,
            shippingAppPath: shippingAppPath, shippingBinaryPath: shippingBinaryPath,
            buildShipping: inputs.buildShipping,
            gitCommit: gitCommit, gitDirty: gitDirty, workspaceFingerprint: workspaceFingerprint
        ) {
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
                projectPath: inputs.appRoot.appendingPathComponent("HarnessMonitor.xcodeproj"),
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
                buildStartedAtUTC: buildStartedAtUTC
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
        let combinedDefaultEnv = baseEnvironment.merging(baseAuditEnv) { _, audit in audit }

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
            selectedScenarios: scenarios
        )
        let manifestPath = runDir.appendingPathComponent("manifest.json")
        try ManifestBuilder.write(manifest, to: manifestPath)

        let exporter = ExtractorOrchestrator.ProcessXctrace(
            command: "/usr/bin/xcrun",
            arguments: ["xctrace"],
            tempRoot: xctraceTempRoot
        )
        _ = try ExtractorOrchestrator.extract(runDir: runDir, exporter: exporter)
        let summaryPath = runDir.appendingPathComponent("summary.json")
        let summaryData = try Data(contentsOf: summaryPath)
        try BudgetEnforcer.enforce(summaryJSON: summaryData)

        var comparisonPath: URL?
        if let baseline = inputs.compareTo {
            _ = try Comparator.compare(.init(current: runDir, baseline: baseline, outputDir: runDir))
            comparisonPath = runDir.appendingPathComponent("comparison.md")
        }

        if !inputs.keepTraces {
            try? FileManager.default.removeItem(at: tracesRoot)
        }
        try RunPruner.prune(runDir: runDir, keepTraces: inputs.keepTraces)

        return RunOutcome(runDir: runDir, summaryPath: summaryPath, comparisonPath: comparisonPath)
    }

    // MARK: - Internals

    private static func recordOne(
        template: String, scenario: String, runDir: URL,
        tracesRoot: URL, xctraceTempRoot: URL,
        staged: HostStager.Result, defaultEnv: [String: String],
        checkoutRoot: URL, appRoot: URL,
        gitCommit: String, workspaceFingerprint: String
    ) throws -> TraceRecorder.Capture {
        let templateSlug = template.lowercased().replacingOccurrences(of: " ", with: "-")
        let templateDir = tracesRoot.appendingPathComponent(templateSlug, isDirectory: true)
        let dataHome = runDir
            .appendingPathComponent("app-data", isDirectory: true)
            .appendingPathComponent(templateSlug, isDirectory: true)
            .appendingPathComponent(scenario, isDirectory: true)
        let logURL = runDir.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("\(templateSlug)-\(scenario).log")
        let traceURL = templateDir.appendingPathComponent("\(scenario).trace", isDirectory: true)
        let tocURL = templateDir.appendingPathComponent("\(scenario).toc.xml")

        var env = defaultEnv
        env["HARNESS_DAEMON_DATA_HOME"] = dataHome.path
        env["HARNESS_MONITOR_PERF_SCENARIO"] = scenario
        env["HARNESS_MONITOR_PREVIEW_SCENARIO"] = ScenarioCatalog.previewScenario(for: scenario)

        try assertSourceUnchanged(
            checkpoint: "before recording \(template) / \(scenario)",
            checkoutRoot: checkoutRoot, appRoot: appRoot,
            gitCommit: gitCommit, workspaceFingerprint: workspaceFingerprint
        )

        let inputs = TraceRecorder.ScenarioInputs(
            scenario: scenario, template: template,
            previewScenario: ScenarioCatalog.previewScenario(for: scenario),
            durationSeconds: ScenarioCatalog.durationSeconds(for: scenario),
            hostAppPath: staged.stagedAppPath,
            hostBinaryPath: staged.stagedBinaryPath,
            launchArguments: persistenceArguments,
            environment: env,
            traceURL: traceURL, tocURL: tocURL, logURL: logURL,
            daemonDataHome: dataHome,
            xctraceTempRoot: xctraceTempRoot
        )
        let capture = try TraceRecorder.record(inputs) {
            cleanupHostProcesses()
            try assertSourceUnchanged(
                checkpoint: "after recording \(template) / \(scenario)",
                checkoutRoot: checkoutRoot, appRoot: appRoot,
                gitCommit: gitCommit, workspaceFingerprint: workspaceFingerprint
            )
        }
        return capture
    }

    private static func appendCaptureTSV(_ url: URL, capture: TraceRecorder.Capture) throws {
        let record = capture.record
        let line = [
            record.scenario, record.template, "\(record.durationSeconds)",
            record.traceRelpath, "\(record.exitStatus)", record.endReason,
            record.previewScenario, record.launchedProcessPath, record.daemonDataHome,
        ].joined(separator: "\t") + "\n"
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try Data(line.utf8).write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    private static func buildManifest(
        label: String, runID: String, createdAtUTC: String,
        gitCommit: String, gitDirty: String,
        workspaceFingerprint: String, buildStartedAtUTC: String,
        arch: String, project: URL,
        hostAppPath: URL, shippingAppPath: URL,
        staged: HostStager.Result,
        buildShipping: Bool, skipDaemonBundle: Bool, daemonCargoTargetDir: URL,
        captureRecords: [ManifestBuilder.CaptureRecord],
        selectedScenarios: [String]
    ) throws -> ManifestBuilder.Manifest {
        let xcodeVersion = try toolVersion("/usr/bin/xcodebuild", arguments: ["-version"])
        let xctraceVersion = try toolVersion("/usr/bin/xcrun", arguments: ["xctrace", "version"])
        let macosVersion = try toolVersion("/usr/bin/sw_vers", arguments: ["-productVersion"])
        let macosBuild = try toolVersion("/usr/bin/sw_vers", arguments: ["-buildVersion"])

        let hostBinary = hostAppPath.appendingPathComponent("Contents/MacOS/Harness Monitor UI Testing")
        let host = ManifestBuilder.BinaryProvenance(
            embeddedCommit: BuildOrchestrator.bundleProvenanceValue(bundle: hostAppPath, key: BuildOrchestrator.buildCommitKey),
            embeddedDirty: BuildOrchestrator.bundleProvenanceValue(bundle: hostAppPath, key: BuildOrchestrator.buildDirtyKey),
            embeddedWorkspaceFingerprint: BuildOrchestrator.bundleProvenanceValue(bundle: hostAppPath, key: BuildOrchestrator.buildWorkspaceFingerprintKey),
            embeddedStartedAtUTC: BuildOrchestrator.bundleProvenanceValue(bundle: hostAppPath, key: BuildOrchestrator.buildStartedAtUTCKey),
            binarySHA256: try BuildOrchestrator.binarySHA256(hostBinary),
            bundleSHA256: try WorkspaceFingerprint.directorySHA256(hostAppPath),
            binaryMtimeUTC: try BuildOrchestrator.binaryMtimeUTC(hostBinary)
        )

        var shipping = ManifestBuilder.ShippingProvenance(
            built: buildShipping,
            embeddedCommit: "", embeddedDirty: "", embeddedWorkspaceFingerprint: "",
            embeddedStartedAtUTC: "", binarySHA256: "", bundleSHA256: "", binaryMtimeUTC: ""
        )
        if buildShipping {
            let shippingBinary = shippingAppPath.appendingPathComponent("Contents/MacOS/Harness Monitor")
            shipping = ManifestBuilder.ShippingProvenance(
                built: true,
                embeddedCommit: BuildOrchestrator.bundleProvenanceValue(bundle: shippingAppPath, key: BuildOrchestrator.buildCommitKey),
                embeddedDirty: BuildOrchestrator.bundleProvenanceValue(bundle: shippingAppPath, key: BuildOrchestrator.buildDirtyKey),
                embeddedWorkspaceFingerprint: BuildOrchestrator.bundleProvenanceValue(bundle: shippingAppPath, key: BuildOrchestrator.buildWorkspaceFingerprintKey),
                embeddedStartedAtUTC: BuildOrchestrator.bundleProvenanceValue(bundle: shippingAppPath, key: BuildOrchestrator.buildStartedAtUTCKey),
                binarySHA256: try BuildOrchestrator.binarySHA256(shippingBinary),
                bundleSHA256: try WorkspaceFingerprint.directorySHA256(shippingAppPath),
                binaryMtimeUTC: try BuildOrchestrator.binaryMtimeUTC(shippingBinary)
            )
        }

        let buildProv = ManifestBuilder.BuildProvenance(
            auditDaemonBundle: ManifestBuilder.AuditDaemonBundle(
                requestedSkip: skipDaemonBundle,
                mode: skipDaemonBundle ? "skipped" : "shared-cargo-target",
                cargoTargetDir: daemonCargoTargetDir.path
            ),
            host: host,
            shipping: shipping
        )

        return ManifestBuilder.build(.init(
            label: label, runID: runID, createdAtUTC: createdAtUTC,
            git: ManifestBuilder.GitProvenance(
                commit: gitCommit, dirty: gitDirty == "true",
                workspaceFingerprint: workspaceFingerprint,
                buildStartedAtUTC: buildStartedAtUTC
            ),
            system: ManifestBuilder.SystemInfo(
                xcodeVersion: xcodeVersion, xctraceVersion: xctraceVersion,
                macosVersion: macosVersion, macosBuild: macosBuild, arch: arch
            ),
            targets: ManifestBuilder.Targets(
                project: project.path,
                shippingScheme: shippingScheme, hostScheme: hostScheme,
                shippingAppPath: shippingAppPath.path, hostAppPath: hostAppPath.path,
                hostBundleID: hostBundleID,
                stagedHostAppPath: staged.stagedAppPath.path,
                stagedHostBinaryPath: staged.stagedBinaryPath.path,
                stagedHostBundleID: staged.stagedBundleID
            ),
            buildProvenance: buildProv,
            defaultEnvironment: baseEnvironment,
            launchArguments: persistenceArguments,
            selectedScenarios: selectedScenarios,
            captureRecords: captureRecords
        ))
    }

    public static func validateProvenance(
        bundle: URL, label: String,
        gitCommit: String, gitDirty: String, workspaceFingerprint: String,
        allowMismatch: Bool
    ) throws {
        let commit = BuildOrchestrator.bundleProvenanceValue(bundle: bundle, key: BuildOrchestrator.buildCommitKey)
        let dirty = BuildOrchestrator.bundleProvenanceValue(bundle: bundle, key: BuildOrchestrator.buildDirtyKey)
        let fp = BuildOrchestrator.bundleProvenanceValue(bundle: bundle, key: BuildOrchestrator.buildWorkspaceFingerprintKey)
        if commit == gitCommit && dirty == gitDirty && fp == workspaceFingerprint { return }
        let detail = "expected commit=\(gitCommit) dirty=\(gitDirty) fingerprint=\(workspaceFingerprint) "
            + "but bundle reports commit=\(commit) dirty=\(dirty) fingerprint=\(fp)"
        if allowMismatch {
            FileHandle.standardError.write(Data("\(label) build provenance mismatch: \(detail). Continuing because skip-build is set.\n".utf8))
            return
        }
        throw Failure(message: "\(label) build provenance mismatch: \(detail)")
    }

    public static func assertSourceUnchanged(
        checkpoint: String, checkoutRoot: URL, appRoot: URL,
        gitCommit: String, workspaceFingerprint: String
    ) throws {
        let currentCommit = try gitRevParseHead(checkoutRoot)
        let currentFingerprint = try WorkspaceFingerprint.compute(variant: .audit, projectDir: appRoot)
        if currentCommit == gitCommit && currentFingerprint == workspaceFingerprint { return }
        throw Failure(
            message: "Audit source changed during \(checkpoint). Built commit=\(gitCommit) fingerprint=\(workspaceFingerprint); current commit=\(currentCommit) fingerprint=\(currentFingerprint). Rerun the audit so Instruments measures the current checkout."
        )
    }

    public static func gitRevParseHead(_ root: URL) throws -> String {
        try gitOutput(root: root, arguments: ["rev-parse", "HEAD"])
    }

    public static func gitDirtyFlag(_ root: URL) throws -> String {
        let result = try ProcessRunner.run("/usr/bin/git", arguments: ["-C", root.path, "status", "--short"])
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
    }

    private static func gitOutput(root: URL, arguments: [String]) throws -> String {
        let result = try ProcessRunner.runChecked(
            "/usr/bin/git",
            arguments: ["-C", root.path] + arguments
        )
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func toolVersion(_ command: String, arguments: [String]) throws -> String {
        let result = try ProcessRunner.run(command, arguments: arguments)
        return result.stdoutString
            .replacingOccurrences(of: "\n", with: ";")
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
    }

    public static func cleanupHostProcesses() {
        let result = (try? ProcessRunner.run("/bin/ps", arguments: ["-Ao", "pid=,command="]))?.stdoutString ?? ""
        for line in result.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let pidString = String(trimmed[..<space])
            let command = String(trimmed[trimmed.index(after: space)...])
            guard let pid = Int32(pidString) else { continue }
            if command.contains("Harness Monitor UI Testing.app/Contents/MacOS/Harness Monitor UI Testing")
                || command.contains("target/debug/harness daemon serve")
                || command.contains("target/debug/harness bridge start")
                || command.contains("/mock-codex") {
                kill(pid, SIGKILL)
            }
        }
    }

    private static func utcCompactTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    private static func utcExtendedTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
