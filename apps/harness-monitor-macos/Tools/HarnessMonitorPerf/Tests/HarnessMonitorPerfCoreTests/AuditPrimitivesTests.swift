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
            selectedScenarios: ["launch-dashboard"],
            captureRecords: [
                .init(
                    scenario: "launch-dashboard", template: "SwiftUI",
                    durationSeconds: 5, traceRelpath: "traces/launch-dashboard.trace",
                    exitStatus: 0, endReason: "completed",
                    previewScenario: "DashboardPreview",
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
        XCTAssertEqual(capture.environment["HARNESS_MONITOR_PERF_SCENARIO"], "launch-dashboard")
        XCTAssertEqual(capture.environment["HARNESS_MONITOR_PREVIEW_SCENARIO"], "DashboardPreview")
        XCTAssertEqual(capture.launchArguments, ["-ApplePersistenceIgnoreState", "YES"])

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

    func testManifestTemplatesIncludeKnownScenarios() {
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("launch-dashboard"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.allocations.contains("offline-cached-open"))
    }
}
