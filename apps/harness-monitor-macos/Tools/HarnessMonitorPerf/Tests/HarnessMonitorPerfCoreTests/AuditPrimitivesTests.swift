import XCTest
@testable import HarnessMonitorPerfCore

final class AuditPrimitivesTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("perf-primitives-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - WorkspaceFingerprint

    func testWorkspaceFingerprintIsStableAcrossRuns() throws {
        let projectDir = workDir.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("Resources"),
            withIntermediateDirectories: true
        )
        try Data("entitlement".utf8).write(
            to: projectDir.appendingPathComponent("HarnessMonitor.entitlements")
        )
        try Data("daemon".utf8).write(
            to: projectDir.appendingPathComponent("HarnessMonitorDaemon.entitlements")
        )
        try Data("res".utf8).write(
            to: projectDir.appendingPathComponent("Resources/Info.plist")
        )

        let first = try WorkspaceFingerprint.compute(variant: .monitorApp, projectDir: projectDir)
        let second = try WorkspaceFingerprint.compute(variant: .monitorApp, projectDir: projectDir)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testWorkspaceFingerprintChangesWhenContentMutates() throws {
        let projectDir = workDir.appendingPathComponent("MutatingProject", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let entitlements = projectDir.appendingPathComponent("HarnessMonitor.entitlements")
        try Data("a".utf8).write(to: entitlements)
        let firstHash = try WorkspaceFingerprint.compute(
            variant: .monitorApp, projectDir: projectDir
        )

        try Data("b".utf8).write(to: entitlements)
        let secondHash = try WorkspaceFingerprint.compute(
            variant: .monitorApp, projectDir: projectDir
        )
        XCTAssertNotEqual(firstHash, secondHash)
    }

    func testWorkspaceFingerprintVariantsDiffer() throws {
        let projectDir = workDir.appendingPathComponent("VariantProject", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("a".utf8).write(
            to: projectDir.appendingPathComponent("HarnessMonitor.entitlements")
        )
        try Data("ui".utf8).write(
            to: projectDir.appendingPathComponent("HarnessMonitorUITestHost.entitlements")
        )
        let monitorApp = try WorkspaceFingerprint.compute(
            variant: .monitorApp, projectDir: projectDir
        )
        let uiTestHost = try WorkspaceFingerprint.compute(
            variant: .uiTestHost, projectDir: projectDir
        )
        XCTAssertNotEqual(monitorApp, uiTestHost)
    }

    // MARK: - ProcessRunner

    func testProcessRunnerCapturesStdoutAndExitCode() throws {
        let result = try ProcessRunner.run("/bin/echo", arguments: ["hello", "world"])
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.stdoutString, "hello world\n")
    }

    func testRunCheckedThrowsOnNonZeroExit() {
        XCTAssertThrowsError(
            try ProcessRunner.runChecked("/bin/sh", arguments: ["-c", "exit 7"])
        ) { error in
            guard let failure = error as? ProcessRunner.Failure else {
                XCTFail("expected ProcessRunner.Failure, got \(error)")
                return
            }
            XCTAssertEqual(failure.exitStatus, 7)
        }
    }

    func testEnvironmentOverridesPropagate() throws {
        let result = try ProcessRunner.runChecked(
            "/bin/sh",
            arguments: ["-c", "printf '%s' \"$PERF_TEST_KEY\""],
            environmentOverrides: ["PERF_TEST_KEY": "abc123"]
        )
        XCTAssertEqual(result.stdoutString, "abc123")
    }

    // MARK: - ManifestBuilder

    func testManifestBuilderProducesCanonicalShape() throws {
        let inputs = ManifestBuilder.Inputs(
            label: "perf",
            runID: "run-1",
            createdAtUTC: "2026-04-25T00:00:00Z",
            git: .init(commit: "deadbeef", dirty: false, workspaceFingerprint: "abc", buildStartedAtUTC: "2026-04-25T00:00:00Z"),
            system: .init(xcodeVersion: "16.0", xctraceVersion: "1.0", macosVersion: "14", macosBuild: "23A", arch: "arm64"),
            targets: .init(
                project: "/p", shippingScheme: "S", hostScheme: "H",
                shippingAppPath: "/s.app", hostAppPath: "/h.app",
                hostBundleID: "io.example.host",
                stagedHostAppPath: "/staged.app",
                stagedHostBinaryPath: "/staged.app/MacOS/Bin",
                stagedHostBundleID: "io.example.staged"
            ),
            buildProvenance: .init(
                auditDaemonBundle: .init(requestedSkip: false, mode: "rebuild", cargoTargetDir: "/t"),
                host: .init(
                    embeddedCommit: "x", embeddedDirty: "false",
                    embeddedWorkspaceFingerprint: "wf",
                    embeddedStartedAtUTC: "2026", binarySHA256: "bs",
                    bundleSHA256: "us", binaryMtimeUTC: "m"
                ),
                shipping: .init(
                    built: false, embeddedCommit: "", embeddedDirty: "",
                    embeddedWorkspaceFingerprint: "", embeddedStartedAtUTC: "",
                    binarySHA256: "", bundleSHA256: "", binaryMtimeUTC: ""
                )
            ),
            defaultEnvironment: ["HARNESS_MONITOR_UI_TESTS": "1"],
            launchArguments: ["-ApplePersistenceIgnoreState", "YES"],
            selectedScenarios: ["open-recent-window"],
            captureRecords: [
                .init(
                    scenario: "open-recent-window", template: "SwiftUI",
                    durationSeconds: 5, traceRelpath: "traces/open-recent-window.trace",
                    exitStatus: 0, endReason: "completed",
                    previewScenario: "dashboard-landing",
                    launchedProcessPath: "/staged.app/MacOS/Bin",
                    daemonDataHome: "/tmp/run-1/dh"
                ),
            ]
        )

        let manifest = ManifestBuilder.build(inputs)
        XCTAssertEqual(manifest.label, "perf")
        XCTAssertEqual(manifest.captures.count, 1)
        let capture = manifest.captures[0]
        XCTAssertEqual(capture.environment["HARNESS_DAEMON_DATA_HOME"], "/tmp/run-1/dh")
        XCTAssertEqual(capture.environment["HARNESS_MONITOR_PERF_SCENARIO"], "open-recent-window")
        XCTAssertEqual(capture.environment["HARNESS_MONITOR_PREVIEW_SCENARIO"], "dashboard-landing")
        XCTAssertEqual(capture.launchArguments, ["-ApplePersistenceIgnoreState", "YES"])
        XCTAssertEqual(capture.daemonDataHomeProbe?.dataHome, "/tmp/run-1/dh")
        XCTAssertFalse(capture.daemonDataHomeProbe?.containsSQLiteDatabase ?? true)

        let url = workDir.appendingPathComponent("manifest.json")
        try ManifestBuilder.write(manifest, to: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("\"label\" : \"perf\""))
        XCTAssertTrue(written.contains("\"selected_scenarios\" : ["))
        // Sorted keys: build_provenance comes before captures alphabetically.
        if
            let buildIndex = written.range(of: "\"build_provenance\""),
            let capturesIndex = written.range(of: "\"captures\"")
        {
            XCTAssertLessThan(buildIndex.lowerBound, capturesIndex.lowerBound)
        }
    }

    func testAuditDefaultEnvironmentPassesThroughLiveDaemonKeysOnly() {
        let environment = AuditRunner.defaultEnvironment(
            processEnvironment: [
                "HARNESS_MONITOR_LAUNCH_MODE": " live ",
                "HARNESS_MONITOR_EXTERNAL_DAEMON": "1",
                "HARNESS_DAEMON_DATA_HOME": "/should/not/pass-through",
                "HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard",
                "UNRELATED": "value",
            ]
        )

        XCTAssertEqual(environment["HARNESS_MONITOR_UI_TESTS"], "1")
        XCTAssertEqual(environment["HARNESS_MONITOR_LAUNCH_MODE"], "live")
        XCTAssertEqual(environment["HARNESS_MONITOR_EXTERNAL_DAEMON"], "1")
        XCTAssertNil(environment["HARNESS_DAEMON_DATA_HOME"])
        XCTAssertNil(environment["HARNESS_MONITOR_PREVIEW_SCENARIO"])
        XCTAssertNil(environment["UNRELATED"])
    }

    func testAuditDaemonDataHomeDefaultsToPerRunScenarioDirectory() {
        let runDir = URL(fileURLWithPath: "/tmp/audit-run", isDirectory: true)
        let dataHome = AuditRunner.daemonDataHome(
            runDir: runDir,
            templateSlug: "swiftui",
            scenario: "open-recent-window",
            processEnvironment: [:]
        )

        XCTAssertEqual(
            dataHome.path,
            "/tmp/audit-run/app-data/swiftui/open-recent-window"
        )
    }

    func testAuditDaemonDataHomeOverrideUsesExistingLiveDatabaseRoot() {
        let runDir = URL(fileURLWithPath: "/tmp/audit-run", isDirectory: true)
        let dataHome = AuditRunner.daemonDataHome(
            runDir: runDir,
            templateSlug: "swiftui",
            scenario: "open-recent-window",
            processEnvironment: [
                AuditRunner.daemonDataHomeOverrideEnvironmentKey:
                    " /Users/me/Library/Group Containers/Q498EB36N4.io.harnessmonitor/runtime-lanes/main "
            ]
        )

        XCTAssertEqual(
            dataHome.path,
            "/Users/me/Library/Group Containers/Q498EB36N4.io.harnessmonitor/runtime-lanes/main"
        )
    }

    func testDaemonDataHomeProbeCapturesRealDatabaseEvidence() throws {
        let dataHome = workDir.appendingPathComponent("data-home", isDirectory: true)
        let daemonDir = dataHome.appendingPathComponent("harness/daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: daemonDir.appendingPathComponent("manifest.json"))
        try Data("db".utf8).write(to: daemonDir.appendingPathComponent("harness.db"))
        try Data("wal".utf8).write(to: daemonDir.appendingPathComponent("harness.db-wal"))
        try Data("shm".utf8).write(to: daemonDir.appendingPathComponent("harness.db-shm"))

        let probe = DaemonDataHomeProbe.capture(dataHome: dataHome)

        XCTAssertTrue(probe.exists)
        XCTAssertEqual(probe.regularFileCount, 4)
        XCTAssertEqual(probe.totalBytes, 10)
        XCTAssertTrue(probe.containsDaemonManifest)
        XCTAssertTrue(probe.containsSQLiteDatabase)
        XCTAssertTrue(probe.containsSQLiteWAL)
        XCTAssertTrue(probe.containsSQLiteSHM)
    }

    func testManifestTemplatesIncludeKnownScenarios() {
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("open-recent-window"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("open-session-window-visual-options-disabled"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("agent-detail-form"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("agent-detail-form-visual-options-disabled"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("decision-detail-form-visual-options-disabled"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("task-detail-form-visual-options-disabled"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("session-search-full"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("session-search-full-visual-options-disabled"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("timeline-filter-form"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("timeline-filter-form-visual-options-disabled"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("permission-modal"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.allocations.contains("offline-cached-open"))
    }

    func testHostStagerUsesUniqueAuditBundleName() throws {
        let sourceApp = workDir.appendingPathComponent("Harness Monitor UI Testing.app", isDirectory: true)
        let sourceContents = sourceApp.appendingPathComponent("Contents", isDirectory: true)
        let sourceMacOS = sourceContents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceMacOS, withIntermediateDirectories: true)
        try Data().write(to: sourceMacOS.appendingPathComponent("Harness Monitor UI Testing"))
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "Harness Monitor UI Testing",
                "CFBundleIdentifier": "io.harnessmonitor.app.ui-testing",
            ],
            format: .xml,
            options: 0
        )
        try plistData.write(to: sourceContents.appendingPathComponent("Info.plist"))

        let staged = try HostStager.stage(
            hostAppPath: sourceApp,
            stageRoot: workDir.appendingPathComponent("staged-host", isDirectory: true),
            stagedBundleID: "io.harnessmonitor.app.ui-testing.audit"
        )

        XCTAssertEqual(staged.stagedAppPath.lastPathComponent, "Harness Monitor UI Testing Audit.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedBinaryPath.path))
        XCTAssertEqual(
            PlistAccessor.value(at: staged.stagedAppPath.appendingPathComponent("Contents/Info.plist"), key: "CFBundleIdentifier"),
            "io.harnessmonitor.app.ui-testing.audit"
        )
    }

    func testCleanupHostProcessesIncludesStagedAuditHost() {
        let psOutput = """
          111 /tmp/perf/harness-monitor-instruments/staged-host/Harness Monitor UI Testing Audit.app/Contents/MacOS/Harness Monitor UI Testing -ApplePersistenceIgnoreState YES
          222 /tmp/perf/harness-monitor-instruments/staged-host/Harness Monitor UI Testing.app/Contents/MacOS/Harness Monitor UI Testing -ApplePersistenceIgnoreState YES
          333 /Applications/Other.app/Contents/MacOS/Other
        """
        var signalled: [Int32] = []

        AuditRunner.cleanupHostProcesses(psOutput: psOutput) { pid in
            signalled.append(pid)
        }

        XCTAssertEqual(signalled, [111, 222])
    }
}
