import XCTest
@testable import HarnessMonitorPerfCore

final class AuditManifestBuilderTests: AuditTempDirectoryTestCase {
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

    func testManifestBuilderCanSeparateLaunchDataHomeFromProbeEvidence() {
        let probe = DaemonDataHomeProbe(
            dataHome: "/Users/me/Library/Group Containers/Q498EB36N4.io.harnessmonitor/runtime-lanes/main",
            exists: true,
            regularFileCount: 4,
            totalBytes: 42,
            containsDaemonManifest: true,
            containsSQLiteDatabase: true,
            containsSQLiteWAL: true,
            containsSQLiteSHM: true
        )
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
            launchArguments: [],
            selectedScenarios: ["open-session-window"],
            captureRecords: [
                .init(
                    scenario: "open-session-window", template: "SwiftUI",
                    durationSeconds: 8, traceRelpath: "traces/open-session-window.trace",
                    exitStatus: 0, endReason: "completed",
                    previewScenario: "dashboard-landing",
                    launchedProcessPath: "/staged.app/MacOS/Bin",
                    daemonDataHome: "/tmp/run-1/app-data-mirrors/swiftui/open-session-window",
                    daemonDataHomeProbe: probe
                ),
            ]
        )

        let capture = ManifestBuilder.build(inputs).captures[0]
        XCTAssertEqual(
            capture.environment["HARNESS_DAEMON_DATA_HOME"],
            "/tmp/run-1/app-data-mirrors/swiftui/open-session-window"
        )
        XCTAssertEqual(capture.daemonDataHomeProbe?.dataHome, probe.dataHome)
        XCTAssertTrue(capture.daemonDataHomeProbe?.containsSQLiteDatabase ?? false)
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
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("sidebar-toggle-rich-detail"))
        XCTAssertTrue(
            ManifestBuilder.defaultTemplates.swiftui.contains(
                "sidebar-toggle-rich-detail-visual-options-disabled"
            )
        )
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("timeline-filter-form"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("timeline-filter-form-visual-options-disabled"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.swiftui.contains("permission-modal"))
        XCTAssertTrue(ManifestBuilder.defaultTemplates.allocations.contains("offline-cached-open"))
    }
}
