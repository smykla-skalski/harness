import Foundation

extension AuditRunner {
    static func recordOne(
        template: String, scenario: String, runDir: URL,
        tracesRoot: URL, xctraceTempRoot: URL,
        staged: HostStager.Result, defaultEnv: [String: String],
        checkoutRoot: URL, appRoot: URL,
        gitCommit: String, workspaceFingerprint: String
    ) throws -> TraceRecorder.Capture {
        let templateSlug = template.lowercased().replacingOccurrences(of: " ", with: "-")
        let templateDir = tracesRoot.appendingPathComponent(templateSlug, isDirectory: true)
        let dataHome = try auditDaemonDataHome(
            runDir: runDir,
            templateSlug: templateSlug,
            scenario: scenario,
            defaultEnvironment: defaultEnv,
            processIsLive: externalDaemonProcessIsLive
        )
        let logURL = runDir.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("\(templateSlug)-\(scenario).log")
        let traceURL = templateDir.appendingPathComponent("\(scenario).trace", isDirectory: true)
        let tocURL = templateDir.appendingPathComponent("\(scenario).toc.xml")

        var env = defaultEnv
        env["HARNESS_DAEMON_DATA_HOME"] = dataHome.launchDataHome.path
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
            daemonDataHome: dataHome.launchDataHome,
            daemonDataHomeProbe: dataHome.probeDataHome,
            xctraceTempRoot: xctraceTempRoot
        )
        return try TraceRecorder.record(inputs) {
            cleanupHostProcesses()
            try assertSourceUnchanged(
                checkpoint: "after recording \(template) / \(scenario)",
                checkoutRoot: checkoutRoot, appRoot: appRoot,
                gitCommit: gitCommit, workspaceFingerprint: workspaceFingerprint
            )
        }
    }

    static func appendCaptureTSV(_ url: URL, capture: TraceRecorder.Capture) throws {
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

    static func buildManifest(
        label: String, runID: String, createdAtUTC: String,
        gitCommit: String, gitDirty: String,
        workspaceFingerprint: String, buildStartedAtUTC: String,
        arch: String, project: URL,
        hostAppPath: URL, shippingAppPath: URL,
        staged: HostStager.Result,
        buildShipping: Bool, skipDaemonBundle: Bool, daemonCargoTargetDir: URL,
        captureRecords: [ManifestBuilder.CaptureRecord],
        selectedScenarios: [String],
        defaultEnvironment: [String: String]
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

        let shipping = try shippingProvenance(
            built: buildShipping,
            shippingAppPath: shippingAppPath
        )
        let buildProv = ManifestBuilder.BuildProvenance(
            auditDaemonBundle: .init(
                requestedSkip: skipDaemonBundle,
                mode: skipDaemonBundle ? "skipped" : "shared-cargo-target",
                cargoTargetDir: daemonCargoTargetDir.path
            ),
            host: host,
            shipping: shipping
        )

        return ManifestBuilder.build(.init(
            label: label, runID: runID, createdAtUTC: createdAtUTC,
            git: .init(
                commit: gitCommit, dirty: gitDirty == "true",
                workspaceFingerprint: workspaceFingerprint,
                buildStartedAtUTC: buildStartedAtUTC
            ),
            system: .init(
                xcodeVersion: xcodeVersion, xctraceVersion: xctraceVersion,
                macosVersion: macosVersion, macosBuild: macosBuild, arch: arch
            ),
            targets: .init(
                project: project.path,
                shippingScheme: shippingScheme, hostScheme: hostScheme,
                shippingAppPath: shippingAppPath.path, hostAppPath: hostAppPath.path,
                hostBundleID: hostBundleID,
                stagedHostAppPath: staged.stagedAppPath.path,
                stagedHostBinaryPath: staged.stagedBinaryPath.path,
                stagedHostBundleID: staged.stagedBundleID
            ),
            buildProvenance: buildProv,
            defaultEnvironment: defaultEnvironment,
            launchArguments: persistenceArguments,
            selectedScenarios: selectedScenarios,
            captureRecords: captureRecords
        ))
    }

    private static func shippingProvenance(
        built: Bool,
        shippingAppPath: URL
    ) throws -> ManifestBuilder.ShippingProvenance {
        guard built else {
            return .init(
                built: false,
                embeddedCommit: "", embeddedDirty: "", embeddedWorkspaceFingerprint: "",
                embeddedStartedAtUTC: "", binarySHA256: "", bundleSHA256: "",
                binaryMtimeUTC: ""
            )
        }
        let binary = shippingAppPath.appendingPathComponent("Contents/MacOS/Harness Monitor")
        return .init(
            built: true,
            embeddedCommit: BuildOrchestrator.bundleProvenanceValue(bundle: shippingAppPath, key: BuildOrchestrator.buildCommitKey),
            embeddedDirty: BuildOrchestrator.bundleProvenanceValue(bundle: shippingAppPath, key: BuildOrchestrator.buildDirtyKey),
            embeddedWorkspaceFingerprint: BuildOrchestrator.bundleProvenanceValue(bundle: shippingAppPath, key: BuildOrchestrator.buildWorkspaceFingerprintKey),
            embeddedStartedAtUTC: BuildOrchestrator.bundleProvenanceValue(bundle: shippingAppPath, key: BuildOrchestrator.buildStartedAtUTCKey),
            binarySHA256: try BuildOrchestrator.binarySHA256(binary),
            bundleSHA256: try WorkspaceFingerprint.directorySHA256(shippingAppPath),
            binaryMtimeUTC: try BuildOrchestrator.binaryMtimeUTC(binary)
        )
    }

    private static func toolVersion(_ command: String, arguments: [String]) throws -> String {
        let result = try ProcessRunner.run(command, arguments: arguments)
        return result.stdoutString
            .replacingOccurrences(of: "\n", with: ";")
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
    }
}
