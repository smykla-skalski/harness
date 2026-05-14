import XCTest
@testable import HarnessMonitorPerfCore

final class ScenarioCatalogTests: XCTestCase {
    func testResolveAllReturnsFullList() throws {
        let resolved = try ScenarioCatalog.resolve("all")
        XCTAssertEqual(resolved, ScenarioCatalog.all)
    }

    func testResolveCommaListPreservesOrderAndTrims() throws {
        let resolved = try ScenarioCatalog.resolve("open-recent-window, offline-cached-open")
        XCTAssertEqual(resolved, ["open-recent-window", "offline-cached-open"])
    }

    func testResolveRejectsUnknownScenario() {
        XCTAssertThrowsError(try ScenarioCatalog.resolve("open-recent-window,bogus")) { error in
            guard let failure = error as? ScenarioCatalog.Failure else {
                XCTFail("expected ScenarioCatalog.Failure")
                return
            }
            XCTAssertTrue(failure.message.contains("bogus"))
        }
    }

    func testResolveEmptySelectionThrows() {
        XCTAssertThrowsError(try ScenarioCatalog.resolve(",  ,"))
    }

    func testDurationsAreStable() {
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "open-recent-window"), 6)
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "open-session-window-visual-options-disabled"), 8)
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "agent-detail-form"), 8)
        XCTAssertEqual(
            ScenarioCatalog.durationSeconds(for: "agent-detail-form-visual-options-disabled"),
            8
        )
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "session-search-full"), 8)
        XCTAssertEqual(
            ScenarioCatalog.durationSeconds(for: "session-search-full-visual-options-disabled"),
            8
        )
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "sidebar-toggle-rich-detail"), 8)
        XCTAssertEqual(
            ScenarioCatalog.durationSeconds(
                for: "sidebar-toggle-rich-detail-visual-options-disabled"
            ),
            8
        )
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "timeline-filter-form"), 8)
        XCTAssertEqual(
            ScenarioCatalog.durationSeconds(for: "timeline-filter-form-visual-options-disabled"),
            8
        )
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "permission-modal"), 8)
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "unknown-scenario"), 8)
    }

    func testPreviewScenarioMapping() {
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "open-recent-window"), "dashboard-landing")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "open-session-window-visual-options-disabled"), "dashboard-landing")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "agent-detail-form"), "dashboard-landing")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "agent-detail-form-visual-options-disabled"), "dashboard-landing")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "decision-detail-form"), "cockpit")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "decision-detail-form-visual-options-disabled"), "cockpit")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "task-detail-form"), "dashboard-landing")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "task-detail-form-visual-options-disabled"), "dashboard-landing")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "session-search-full"), "dashboard-landing")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "session-search-full-visual-options-disabled"), "dashboard-landing")
        XCTAssertEqual(
            ScenarioCatalog.previewScenario(for: "sidebar-toggle-rich-detail"),
            "dashboard-landing"
        )
        XCTAssertEqual(
            ScenarioCatalog.previewScenario(
                for: "sidebar-toggle-rich-detail-visual-options-disabled"
            ),
            "dashboard-landing"
        )
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "timeline-filter-form"), "dashboard-landing")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "timeline-filter-form-visual-options-disabled"), "dashboard-landing")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "permission-modal"), "cockpit")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "offline-cached-open"), "offline-cached")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "anything-else"), "dashboard")
    }

    func testTemplateRoutingMatchesCatalog() {
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("permission-modal"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("open-session-window-visual-options-disabled"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("agent-detail-form"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("agent-detail-form-visual-options-disabled"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("decision-detail-form"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("decision-detail-form-visual-options-disabled"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("task-detail-form"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("task-detail-form-visual-options-disabled"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("session-search-full"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("session-search-full-visual-options-disabled"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("sidebar-toggle-rich-detail"))
        XCTAssertTrue(
            ScenarioCatalog.swiftUI.contains("sidebar-toggle-rich-detail-visual-options-disabled")
        )
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("timeline-filter-form"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("timeline-filter-form-visual-options-disabled"))
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("toast-overlay-churn"))
        XCTAssertFalse(ScenarioCatalog.swiftUI.contains("settings-backdrop-cycle"))
        XCTAssertTrue(ScenarioCatalog.allocations.contains("settings-background-cycle"))
        XCTAssertTrue(ScenarioCatalog.allocations.contains("offline-cached-open"))
    }
}

final class AuditVariantTests: XCTestCase {
    func testDefaultMatrixVariantsCoverCurrentIsolationAxes() throws {
        let variants = try AuditVariant.resolve(nil)
        XCTAssertEqual(
            variants.map(\.id),
            [
                "baseline",
                "no-search-host",
                "no-search-suggestions",
                "scene-writes-enabled",
                "static-detail",
            ]
        )
    }

    func testVariantEnvironmentMapsToAppIsolationFlags() throws {
        let variants = try AuditVariant.resolve(
            "no-search-host,no-search-suggestions,scene-writes-enabled,static-detail"
        )
        let environment = variants.reduce(into: [String: String]()) {
            $0.merge($1.environment) { _, new in new }
        }
        XCTAssertEqual(environment["HARNESS_MONITOR_PERF_DISABLE_SEARCH_HOST"], "1")
        XCTAssertEqual(environment["HARNESS_MONITOR_PERF_DISABLE_SEARCH_SUGGESTIONS"], "1")
        XCTAssertEqual(environment["HARNESS_MONITOR_PERF_ENABLE_SCENE_WRITES"], "1")
        XCTAssertEqual(environment["HARNESS_MONITOR_PERF_STATIC_DETAIL"], "1")
    }
}

final class RunPrunerTests: XCTestCase {
    func testRetainKeepsManifestAndSummary() {
        XCTAssertTrue(RunPruner.retain(relativePath: "manifest.json", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "summary.json", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "summary.csv", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "log-only-summary.json", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "captures.tsv", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "debug-retention.json", keepTraces: false))
    }

    func testRetainScopedMetricsAndLogs() {
        XCTAssertTrue(RunPruner.retain(relativePath: "logs/anything.log", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "metrics/open-recent-window/swiftui.json", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "metrics/open-session-window/top-offenders.json", keepTraces: false))
        XCTAssertFalse(RunPruner.retain(relativePath: "metrics/open-recent-window/raw.json", keepTraces: false))
    }

    func testTracesGatedByKeepFlag() {
        XCTAssertFalse(RunPruner.retain(relativePath: "traces/swiftui/launch.trace", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "traces/swiftui/launch.trace", keepTraces: true))
        XCTAssertTrue(
            RunPruner.retain(
                relativePath: "traces/swiftui/launch.trace",
                keepTraces: false,
                debugRetention: true
            )
        )
    }

    func testNestedComparisonRetained() {
        XCTAssertTrue(RunPruner.retain(relativePath: "comparison-baseline/comparison.json", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "comparison-baseline/comparison.md", keepTraces: false))
    }

    func testDebugRetentionKeepsExportsAndLaunchMetrics() {
        XCTAssertTrue(
            RunPruner.retain(
                relativePath: "exports/open-recent-window/swiftui/swiftui-updates.xml",
                keepTraces: false,
                debugRetention: true
            )
        )
        XCTAssertTrue(
            RunPruner.retain(
                relativePath: "launch-metrics/open-recent-window/swiftui.json",
                keepTraces: false,
                debugRetention: true
            )
        )
        XCTAssertFalse(
            RunPruner.retain(
                relativePath: "exports/open-recent-window/swiftui/swiftui-updates.xml",
                keepTraces: false,
                debugRetention: false
            )
        )
    }
}

final class PlistAccessorTests: XCTestCase {
    func testUpsertStringAndBoolRoundTrips() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("perf-plist-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["existing": "value"], format: .xml, options: 0
        )
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try PlistAccessor.upsertString(at: url, key: "Name", value: "Hello")
        try PlistAccessor.upsertBool(at: url, key: "Flag", value: true)

        XCTAssertEqual(PlistAccessor.value(at: url, key: "Name"), "Hello")
        XCTAssertEqual(PlistAccessor.value(at: url, key: "Flag"), "true")
        XCTAssertEqual(PlistAccessor.value(at: url, key: "existing"), "value")
    }
}

final class TraceRecorderCommandTests: XCTestCase {
    func testEnvFlagsAreSorted() {
        let inputs = TraceRecorder.ScenarioInputs(
            scenario: "open-recent-window", template: "SwiftUI",
            previewScenario: "dashboard-landing", durationSeconds: 6,
            hostAppPath: URL(fileURLWithPath: "/staged.app"),
            hostBinaryPath: URL(fileURLWithPath: "/staged.app/Contents/MacOS/App"),
            launchArguments: ["-X"],
            environment: ["B": "2", "A": "1"],
            traceURL: URL(fileURLWithPath: "/t.trace"),
            tocURL: URL(fileURLWithPath: "/t.toc.xml"),
            logURL: URL(fileURLWithPath: "/log.log"),
            daemonDataHome: URL(fileURLWithPath: "/dh"),
            xctraceTempRoot: URL(fileURLWithPath: "/tmp")
        )
        let (_, arguments) = TraceRecorder.recordCommand(inputs)
        let envArguments = zip(arguments.dropLast(), arguments.dropFirst())
            .filter { $0.0 == "--env" }
            .map { $0.1 }
        XCTAssertEqual(envArguments, ["A=1", "B=2"])
        guard let separator = arguments.firstIndex(of: "--launch") else {
            XCTFail("expected --launch")
            return
        }
        XCTAssertEqual(arguments[separator..<arguments.count],
                       ["--launch", "--", "/staged.app", "-X"])
    }
}

final class LogProbeRecorderTests: XCTestCase {
    func testOpenCommandSortsEnvironmentAndPassesLaunchArguments() {
        let inputs = LogProbeRecorder.ScenarioInputs(
            scenario: "session-search-full",
            previewScenario: "dashboard-landing",
            durationSeconds: 8,
            hostAppPath: URL(fileURLWithPath: "/staged.app"),
            hostBinaryPath: URL(fileURLWithPath: "/staged.app/Contents/MacOS/App"),
            launchArguments: ["-ApplePersistenceIgnoreState", "YES"],
            environment: ["Z": "last", "A": "first"],
            logURL: URL(fileURLWithPath: "/log.log"),
            stdoutURL: URL(fileURLWithPath: "/stdout.log"),
            stderrURL: URL(fileURLWithPath: "/stderr.log"),
            daemonDataHome: URL(fileURLWithPath: "/dh"),
            runDir: URL(fileURLWithPath: "/run")
        )

        let (_, arguments) = LogProbeRecorder.openCommand(inputs)
        let envArguments = zip(arguments.dropLast(), arguments.dropFirst())
            .filter { $0.0 == "--env" }
            .map { $0.1 }
        XCTAssertEqual(envArguments, ["A=first", "Z=last"])
        XCTAssertEqual(
            Array(arguments.suffix(4)),
            ["/staged.app", "--args", "-ApplePersistenceIgnoreState", "YES"]
        )
    }

    func testWarningSummaryCountsKnownRuntimeWarnings() {
        let summary = LogProbeRecorder.warningSummary(in: """
        onChange(of:) action tried to update multiple times per frame.
        Application performed a reentrant operation in its NSTableView delegate.
        AttributeGraph: cycle detected through attribute 123.
        error returned from database: unable to open database file
        Harness Monitor UI Testing Audit.app would like to access data from other apps.
        Class _TtC22HarnessMonitorRegistry is implemented in both A and B.
        Class _TtC22HarnessMonitorRegistry is implemented in both A and B.
        Publishing changes from within view updates is not allowed.
        Main Thread Checker: UI API called on a background thread.
        Sandbox: Harness Monitor deny(1) file-read-data /private/tmp/nope
        SQLite error 14
        """)

        XCTAssertEqual(summary.swiftUIFrameUpdateWarnings, 1)
        XCTAssertEqual(summary.tableViewReentrantWarnings, 1)
        XCTAssertEqual(summary.attributeGraphCycleWarnings, 1)
        XCTAssertEqual(summary.databaseOpenWarnings, 1)
        XCTAssertEqual(summary.appDataPromptHints, 1)
        XCTAssertEqual(summary.duplicateRuntimeClassWarnings, 1)
        XCTAssertEqual(summary.stateMutationWarnings, 1)
        XCTAssertEqual(summary.mainThreadCheckerWarnings, 1)
        XCTAssertEqual(summary.sandboxDenials, 1)
        XCTAssertEqual(summary.sqliteWarnings, 1)
    }

    func testLogShowCommandFiltersKnownAppleCoreSpotlightNoise() {
        let (_, arguments) = LogProbeRecorder.logShowCommand(processID: 123, windowSeconds: 45)

        XCTAssertEqual(arguments.suffix(2).first, "--predicate")
        XCTAssertEqual(
            arguments.last,
            """
            processID == 123 && !((subsystem == "com.apple.corespotlight") && (eventMessage CONTAINS[c] "MailCS"))
            """
        )
    }
}

final class AppTraceParserTests: AuditTempDirectoryTestCase {
    func testSummarizeRecordsOrderedStepsAndStepTimings() throws {
        let traceURL = workDir.appendingPathComponent("app-trace.jsonl")
        try Data(
            """
            {"component":"perf.scenario","details":{"step":"route.agents"},"event":"step.begin","timestamp":"2026-05-14T06:00:00.000Z"}
            {"component":"perf.scenario","details":{"step":"route.agents"},"event":"step.end","timestamp":"2026-05-14T06:00:00.125Z"}
            {"component":"perf.search","details":{"rows":"3"},"event":"suggestions.update","timestamp":"2026-05-14T06:00:00.200Z"}
            """.utf8
        ).write(to: traceURL)

        let trace = try AppTraceParser.summarize(fileURL: traceURL, relpath: "app-trace.jsonl")

        XCTAssertEqual(trace.eventCount, 3)
        XCTAssertEqual(trace.orderedSteps, ["route.agents"])
        XCTAssertEqual(trace.stepTimings.map { $0.step }, ["route.agents"])
        XCTAssertEqual(trace.stepTimings.first?.durationMilliseconds, 125)
        XCTAssertEqual(trace.components.first?.component, "perf.scenario")
    }
}
