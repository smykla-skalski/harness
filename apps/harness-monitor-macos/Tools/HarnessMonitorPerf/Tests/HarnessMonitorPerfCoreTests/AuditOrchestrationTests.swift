import XCTest
@testable import HarnessMonitorPerfCore

final class ScenarioCatalogTests: XCTestCase {
    func testResolveAllReturnsFullList() throws {
        let resolved = try ScenarioCatalog.resolve("all")
        XCTAssertEqual(resolved, ScenarioCatalog.all)
    }

    func testResolveCommaListPreservesOrderAndTrims() throws {
        let resolved = try ScenarioCatalog.resolve("launch-dashboard, offline-cached-open")
        XCTAssertEqual(resolved, ["launch-dashboard", "offline-cached-open"])
    }

    func testResolveRejectsUnknownScenario() {
        XCTAssertThrowsError(try ScenarioCatalog.resolve("launch-dashboard,bogus")) { error in
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
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "launch-dashboard"), 6)
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "refresh-and-search"), 10)
        XCTAssertEqual(ScenarioCatalog.durationSeconds(for: "unknown-scenario"), 8)
    }

    func testPreviewScenarioMapping() {
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "launch-dashboard"), "dashboard-landing")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "offline-cached-open"), "offline-cached")
        XCTAssertEqual(ScenarioCatalog.previewScenario(for: "anything-else"), "dashboard")
    }

    func testTemplateRoutingMatchesShellLists() {
        XCTAssertTrue(ScenarioCatalog.swiftUI.contains("toast-overlay-churn"))
        XCTAssertFalse(ScenarioCatalog.swiftUI.contains("settings-backdrop-cycle"))
        XCTAssertTrue(ScenarioCatalog.allocations.contains("settings-background-cycle"))
        XCTAssertTrue(ScenarioCatalog.allocations.contains("offline-cached-open"))
    }
}

final class RunPrunerTests: XCTestCase {
    func testRetainKeepsManifestAndSummary() {
        XCTAssertTrue(RunPruner.retain(relativePath: "manifest.json", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "summary.json", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "summary.csv", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "captures.tsv", keepTraces: false))
    }

    func testRetainScopedMetricsAndLogs() {
        XCTAssertTrue(RunPruner.retain(relativePath: "logs/anything.log", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "metrics/launch-dashboard/swiftui.json", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "metrics/select-session-cockpit/top-offenders.json", keepTraces: false))
        XCTAssertFalse(RunPruner.retain(relativePath: "metrics/launch-dashboard/raw.json", keepTraces: false))
    }

    func testTracesGatedByKeepFlag() {
        XCTAssertFalse(RunPruner.retain(relativePath: "traces/swiftui/launch.trace", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "traces/swiftui/launch.trace", keepTraces: true))
    }

    func testNestedComparisonRetained() {
        XCTAssertTrue(RunPruner.retain(relativePath: "comparison-baseline/comparison.json", keepTraces: false))
        XCTAssertTrue(RunPruner.retain(relativePath: "comparison-baseline/comparison.md", keepTraces: false))
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
            scenario: "launch-dashboard", template: "SwiftUI",
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
