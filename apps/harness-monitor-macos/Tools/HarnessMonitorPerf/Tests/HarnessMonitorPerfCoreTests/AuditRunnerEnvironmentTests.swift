import XCTest
@testable import HarnessMonitorPerfCore

final class AuditRunnerEnvironmentTests: AuditTempDirectoryTestCase {
    func testAuditDefaultEnvironmentPassesThroughLiveDaemonAndVisualOverrideKeysOnly() {
        let environment = AuditRunner.defaultEnvironment(
            processEnvironment: [
                "HARNESS_MONITOR_LAUNCH_MODE": " live ",
                "HARNESS_MONITOR_EXTERNAL_DAEMON": "1",
                "HARNESS_MONITOR_SESSION_TITLE_BLUR_OVERRIDE": "0",
                "HARNESS_MONITOR_SESSION_SHORTCUT_OVERLAYS_OVERRIDE": "0",
                "HARNESS_MONITOR_MENU_BAR_STATE_COLORS_OVERRIDE": "0",
                "HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE": "none",
                "HARNESS_DAEMON_DATA_HOME": "/should/not/pass-through",
                "HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard",
                "UNRELATED": "value",
            ]
        )

        XCTAssertEqual(environment["HARNESS_MONITOR_UI_TESTS"], "1")
        XCTAssertEqual(environment["HARNESS_MONITOR_LAUNCH_MODE"], "live")
        XCTAssertEqual(environment["HARNESS_MONITOR_EXTERNAL_DAEMON"], "1")
        XCTAssertEqual(environment["HARNESS_MONITOR_SESSION_TITLE_BLUR_OVERRIDE"], "0")
        XCTAssertEqual(environment["HARNESS_MONITOR_SESSION_SHORTCUT_OVERLAYS_OVERRIDE"], "0")
        XCTAssertEqual(environment["HARNESS_MONITOR_MENU_BAR_STATE_COLORS_OVERRIDE"], "0")
        XCTAssertEqual(environment["HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE"], "none")
        XCTAssertNil(environment["HARNESS_DAEMON_DATA_HOME"])
        XCTAssertNil(environment["HARNESS_MONITOR_PREVIEW_SCENARIO"])
        XCTAssertNil(environment["UNRELATED"])
    }

    func testAuditDefaultEnvironmentInfersLiveExternalModeForAuditDataHomeOverride() {
        let environment = AuditRunner.defaultEnvironment(
            processEnvironment: [
                AuditRunner.daemonDataHomeOverrideEnvironmentKey: "/protected/live-data-home",
            ]
        )

        XCTAssertEqual(environment["HARNESS_MONITOR_LAUNCH_MODE"], "live")
        XCTAssertEqual(environment["HARNESS_MONITOR_EXTERNAL_DAEMON"], "1")
        XCTAssertNil(environment["HARNESS_DAEMON_DATA_HOME"])
    }

    func testAuditExternalDaemonReleaseOptInRequiresLiveExternalEnvironment() {
        XCTAssertTrue(
            AuditRunner.shouldAllowExternalDaemonAudit(
                defaultEnvironment: [
                    "HARNESS_MONITOR_LAUNCH_MODE": "live",
                    "HARNESS_MONITOR_EXTERNAL_DAEMON": "1",
                ]
            )
        )
        XCTAssertFalse(
            AuditRunner.shouldAllowExternalDaemonAudit(
                defaultEnvironment: [
                    "HARNESS_MONITOR_LAUNCH_MODE": "preview",
                    "HARNESS_MONITOR_EXTERNAL_DAEMON": "1",
                ]
            )
        )
        XCTAssertFalse(
            AuditRunner.shouldAllowExternalDaemonAudit(
                defaultEnvironment: [
                    "HARNESS_MONITOR_LAUNCH_MODE": "live",
                    "HARNESS_MONITOR_EXTERNAL_DAEMON": "0",
                ]
            )
        )
    }

    func testReleaseBuildSettingsGateAuditExternalDaemonCondition() {
        let defaultSettings = BuildOrchestrator.releaseBuildSettings(
            arch: "arm64",
            allowExternalDaemonAudit: false
        )
        XCTAssertFalse(
            defaultSettings.contains {
                $0.contains("HARNESS_MONITOR_AUDIT_EXTERNAL_DAEMON")
            }
        )

        let externalSettings = BuildOrchestrator.releaseBuildSettings(
            arch: "arm64",
            allowExternalDaemonAudit: true
        )
        XCTAssertTrue(
            externalSettings.contains {
                $0.contains("HARNESS_MONITOR_AUDIT_EXTERNAL_DAEMON")
            }
        )
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

    func testAuditDaemonDataHomeRejectsUnsafeExternalOverrideBeforeLaunch() throws {
        let runDir = URL(fileURLWithPath: "/tmp/audit-run", isDirectory: true)

        XCTAssertThrowsError(
            try AuditRunner.auditDaemonDataHome(
                runDir: runDir,
                templateSlug: "swiftui",
                scenario: "open-session-window",
                defaultEnvironment: [
                    "HARNESS_MONITOR_LAUNCH_MODE": "preview",
                    "HARNESS_MONITOR_EXTERNAL_DAEMON": "0",
                ],
                processEnvironment: [
                    AuditRunner.daemonDataHomeOverrideEnvironmentKey:
                        "/Users/me/Library/Group Containers/Q498EB36N4.io.harnessmonitor/runtime-lanes/main",
                ]
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "HARNESS_MONITOR_AUDIT_DAEMON_DATA_HOME requires"
                )
            )
        }
    }

    func testAuditDaemonDataHomeMirrorsExternalManifestForLaunch() throws {
        let sourceDataHome = workDir.appendingPathComponent("source-data-home", isDirectory: true)
        let sourceDaemonRoot = sourceDataHome
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDaemonRoot, withIntermediateDirectories: true)
        let sourceTokenURL = sourceDaemonRoot.appendingPathComponent("auth-token")
        try Data("secret-token".utf8).write(to: sourceTokenURL)
        let sourceManifestURL = sourceDaemonRoot.appendingPathComponent("manifest.json")
        try Data("""
        {
          "endpoint": "http://127.0.0.1:60385",
          "pid": 123,
          "started_at": "2026-05-12T15:45:43Z",
          "token_path": "\(sourceTokenURL.path)",
          "version": "34.1.0"
        }
        """.utf8).write(to: sourceManifestURL)

        let runDir = workDir.appendingPathComponent("audit-run", isDirectory: true)
        let dataHome = try AuditRunner.auditDaemonDataHome(
            runDir: runDir,
            templateSlug: "swiftui",
            scenario: "open-session-window",
            defaultEnvironment: [
                "HARNESS_MONITOR_LAUNCH_MODE": "live",
                "HARNESS_MONITOR_EXTERNAL_DAEMON": "1",
            ],
            processEnvironment: [
                AuditRunner.daemonDataHomeOverrideEnvironmentKey: sourceDataHome.path,
            ]
        )

        XCTAssertTrue(dataHome.mirroredManifest)
        XCTAssertEqual(dataHome.probeDataHome.path, sourceDataHome.path)
        XCTAssertEqual(
            dataHome.launchDataHome.path,
            runDir.appendingPathComponent("app-data-mirrors/swiftui/open-session-window").path
        )

        let mirrorDaemonRoot = dataHome.launchDataHome
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent(AuditRunner.auditTargetOwnershipSegment, isDirectory: true)
        let mirrorManifestURL = mirrorDaemonRoot.appendingPathComponent("manifest.json")
        let mirrorTokenURL = mirrorDaemonRoot.appendingPathComponent("auth-token")
        let mirrorManifestData = try Data(contentsOf: mirrorManifestURL)
        let mirrorManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mirrorManifestData) as? [String: Any]
        )
        XCTAssertEqual(mirrorManifest["endpoint"] as? String, "http://127.0.0.1:60385")
        XCTAssertEqual(mirrorManifest["token_path"] as? String, mirrorTokenURL.path)
        XCTAssertEqual(try String(contentsOf: mirrorTokenURL, encoding: .utf8), "secret-token")

        let permissions = try FileManager.default
            .attributesOfItem(atPath: mirrorTokenURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue ?? 0, 0o600)
    }

    func testAuditDaemonDataHomeMirrorsExternalManifestFromPartitionedSource() throws {
        let sourceDataHome = workDir.appendingPathComponent("source-data-home", isDirectory: true)
        let sourceDaemonRoot = sourceDataHome
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDaemonRoot, withIntermediateDirectories: true)
        let sourceTokenURL = sourceDaemonRoot.appendingPathComponent("auth-token")
        try Data("secret-token".utf8).write(to: sourceTokenURL)
        let sourceManifestURL = sourceDaemonRoot.appendingPathComponent("manifest.json")
        try Data("""
        {
          "endpoint": "http://127.0.0.1:60385",
          "ownership": "external",
          "pid": 123,
          "started_at": "2026-05-16T15:55:53Z",
          "token_path": "\(sourceTokenURL.path)",
          "version": "35.3.0"
        }
        """.utf8).write(to: sourceManifestURL)

        let runDir = workDir.appendingPathComponent("audit-run", isDirectory: true)
        let dataHome = try AuditRunner.auditDaemonDataHome(
            runDir: runDir,
            templateSlug: "swiftui",
            scenario: "dashboard-live-interact",
            defaultEnvironment: [
                "HARNESS_MONITOR_LAUNCH_MODE": "live",
                "HARNESS_MONITOR_EXTERNAL_DAEMON": "1",
            ],
            processEnvironment: [
                AuditRunner.daemonDataHomeOverrideEnvironmentKey: sourceDataHome.path,
            ]
        )

        XCTAssertTrue(dataHome.mirroredManifest)
        let mirrorDaemonRoot = dataHome.launchDataHome
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent(AuditRunner.auditTargetOwnershipSegment, isDirectory: true)
        let mirrorManifestURL = mirrorDaemonRoot.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirrorManifestURL.path))
        let mirrorManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: mirrorManifestURL)) as? [String: Any]
        )
        XCTAssertEqual(mirrorManifest["endpoint"] as? String, "http://127.0.0.1:60385")
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
}
