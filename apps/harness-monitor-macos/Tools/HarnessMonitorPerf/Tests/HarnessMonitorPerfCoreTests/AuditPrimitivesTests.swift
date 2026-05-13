import XCTest
@testable import HarnessMonitorPerfCore

final class AuditPrimitivesTests: AuditTempDirectoryTestCase {
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
        XCTAssertFalse(result.timedOut)
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

    func testProcessRunnerTerminatesTimedOutProcess() throws {
        let start = Date()
        let result = try ProcessRunner.run(
            "/bin/sleep",
            arguments: ["5"],
            timeoutSeconds: 0.1,
            terminationGraceSeconds: 0.1
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testProcessRunnerReturnsStdoutWhenTimeoutIsUnused() throws {
        let result = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "printf 'ready'"],
            timeoutSeconds: 5
        )
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.stdoutString, "ready")
        XCTAssertFalse(result.timedOut)
    }

    // MARK: - HostStager

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
