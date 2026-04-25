import XCTest
@testable import HarnessMonitorPerfCore

final class ExtractorOrchestratorTests: XCTestCase {
    private var runDir: URL!

    override func setUpWithError() throws {
        runDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("perf-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: runDir)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name, withExtension: "xml", subdirectory: "Fixtures/xml"
            )
        )
        return try Data(contentsOf: url)
    }

    /// Routes xctrace requests to the bundled XML fixtures so the orchestrator runs without
    /// hitting Instruments.
    final class FixtureExporter: ExtractorOrchestrator.XctraceExporting {
        let toc: Data
        let swiftUIQueries: [String: Data]
        let allocationsQuery: Data?

        init(toc: Data, swiftUIQueries: [String: Data] = [:], allocationsQuery: Data? = nil) {
            self.toc = toc
            self.swiftUIQueries = swiftUIQueries
            self.allocationsQuery = allocationsQuery
        }

        func exportTOC(tracePath: URL) throws -> Data { toc }

        func exportQuery(tracePath: URL, xpath: String) throws -> Data {
            for (name, payload) in swiftUIQueries where xpath.contains("\"\(name)\"") {
                return payload
            }
            if let allocationsQuery, xpath == ExtractorOrchestrator.allocationsXPath {
                return allocationsQuery
            }
            return Data("<?xml version=\"1.0\"?><trace-query-result><node><schema/></node></trace-query-result>".utf8)
        }
    }

    func testExtractWritesPerCaptureMetricsAndSummary() throws {
        let manifest = """
        {
          "label": "perf",
          "created_at_utc": "2026-04-25T00:00:00Z",
          "captures": [
            {"scenario": "launch-dashboard", "template": "SwiftUI", "trace_relpath": "traces/launch.trace", "duration_seconds": 5, "exit_status": 0, "end_reason": "completed"},
            {"scenario": "offline-cached-open", "template": "Allocations", "trace_relpath": "traces/offline.trace", "duration_seconds": 3, "exit_status": 0, "end_reason": "completed"}
          ]
        }
        """
        try Data(manifest.utf8).write(to: runDir.appendingPathComponent("manifest.json"), options: .atomic)

        let exporter = FixtureExporter(
            toc: try fixtureData("toc-minimal"),
            swiftUIQueries: [
                "swiftui-updates": try fixtureData("swiftui-updates-minimal"),
                "swiftui-update-groups": try fixtureData("swiftui-update-groups-minimal"),
                "swiftui-causes": try fixtureData("swiftui-causes-minimal"),
                "hitches": try fixtureData("hitches-minimal"),
                "potential-hangs": try fixtureData("hitches-minimal"),
                "time-profile": try fixtureData("time-profile-minimal"),
            ],
            allocationsQuery: try fixtureData("allocations-statistics-minimal")
        )

        let summary = try ExtractorOrchestrator.extract(runDir: runDir, exporter: exporter)
        XCTAssertEqual(summary.label, "perf")
        XCTAssertEqual(summary.captures.count, 2)

        let swiftUIPath = runDir.appendingPathComponent("metrics/launch-dashboard/swiftui.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: swiftUIPath.path))
        let swiftUIData = try Data(contentsOf: swiftUIPath)
        XCTAssertTrue(String(data: swiftUIData, encoding: .utf8)!.contains("\"swiftui_updates\""))

        let allocationsPath = runDir.appendingPathComponent("metrics/offline-cached-open/allocations.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: allocationsPath.path))

        let topOffenders = runDir.appendingPathComponent("metrics/launch-dashboard/top-offenders.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: topOffenders.path))

        XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("summary.csv").path))
    }
}

final class AuditLockTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("perf-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testAcquireWritesInfoAndReleaseRemovesIt() throws {
        let lockDir = workDir.appendingPathComponent("audit-lock", isDirectory: true)
        let info = AuditLock.Info(
            runID: "run-1", label: "perf",
            startedAtUTC: "2026-04-25T00:00:00Z",
            runDir: workDir.path, pid: ProcessInfo.processInfo.processIdentifier
        )
        try AuditLock.acquire(at: lockDir, info: info)
        let infoURL = lockDir.appendingPathComponent("info.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: infoURL.path))
        AuditLock.release(at: lockDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path))
    }

    func testAcquireFailsWhenLiveProcessHoldsLock() throws {
        let lockDir = workDir.appendingPathComponent("audit-lock-2", isDirectory: true)
        let info = AuditLock.Info(
            runID: "run-1", label: "perf",
            startedAtUTC: "2026-04-25T00:00:00Z",
            runDir: workDir.path, pid: ProcessInfo.processInfo.processIdentifier
        )
        try AuditLock.acquire(at: lockDir, info: info)
        XCTAssertThrowsError(try AuditLock.acquire(at: lockDir, info: info)) { error in
            guard let failure = error as? AuditLock.Failure else {
                XCTFail("expected Failure, got \(error)")
                return
            }
            XCTAssertTrue(failure.message.contains("audit already in progress"))
        }
        AuditLock.release(at: lockDir)
    }

    func testAcquireReplacesStaleLock() throws {
        let lockDir = workDir.appendingPathComponent("audit-lock-3", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        let stale = AuditLock.Info(
            runID: "run-stale", label: "old",
            startedAtUTC: "2025-01-01T00:00:00Z",
            runDir: workDir.path, pid: 999_999
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(stale)
        try data.write(to: lockDir.appendingPathComponent("info.json"))

        let live = AuditLock.Info(
            runID: "run-live", label: "perf",
            startedAtUTC: "2026-04-25T00:00:00Z",
            runDir: workDir.path, pid: ProcessInfo.processInfo.processIdentifier
        )
        try AuditLock.acquire(at: lockDir, info: live)
        let written = try Data(contentsOf: lockDir.appendingPathComponent("info.json"))
        let decoded = try JSONDecoder().decode(AuditLock.Info.self, from: written)
        XCTAssertEqual(decoded.runID, "run-live")
        AuditLock.release(at: lockDir)
    }
}

final class TraceRecorderTests: XCTestCase {
    func testRecordCommandIncludesAllExpectedFlags() {
        let inputs = TraceRecorder.ScenarioInputs(
            scenario: "launch-dashboard",
            template: "SwiftUI",
            previewScenario: "DashboardPreview",
            durationSeconds: 6,
            hostBinary: URL(fileURLWithPath: "/staged/Bin"),
            launchArguments: ["-ApplePersistenceIgnoreState", "YES"],
            environment: ["HARNESS_MONITOR_PERF_SCENARIO": "launch-dashboard"],
            traceURL: URL(fileURLWithPath: "/run/traces/launch.trace"),
            logURL: URL(fileURLWithPath: "/run/logs/launch.log"),
            daemonDataHome: URL(fileURLWithPath: "/run/dh")
        )
        let (command, arguments) = TraceRecorder.recordCommand(inputs)
        XCTAssertEqual(command, "/usr/bin/xcrun")
        XCTAssertEqual(arguments[0...3], ["xctrace", "record", "--template", "SwiftUI"])
        XCTAssertTrue(arguments.contains("--time-limit"))
        XCTAssertTrue(arguments.contains("6s"))
        XCTAssertTrue(arguments.contains("--launch"))
        XCTAssertTrue(arguments.contains("/staged/Bin"))
        XCTAssertTrue(arguments.contains("--output"))
        XCTAssertTrue(arguments.contains("/run/traces/launch.trace"))
        // Launch args appear after `--`.
        XCTAssertTrue(arguments.contains("-ApplePersistenceIgnoreState"))
        XCTAssertTrue(arguments.contains("YES"))
    }
}
