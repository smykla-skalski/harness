import XCTest
@testable import HarnessMonitorPerfCore

final class SummarizerTests: XCTestCase {
    private var runDir: URL!

    override func setUpWithError() throws {
        runDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("perf-summarizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: runDir)
    }

    private func writeJSON(_ payload: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(payload.utf8).write(to: url, options: .atomic)
    }

    private func seedRun() throws {
        let manifest = """
        {
          "label": "step3",
          "created_at_utc": "2026-04-25T12:00:00Z",
          "git": {"commit": "deadbeef"},
          "system": {"machine": "arm64"},
          "targets": {"app": "HarnessMonitor"},
          "selected_scenarios": ["open-recent-window", "offline-cached-open"],
          "captures": [
            {
              "scenario": "open-recent-window",
              "template": "SwiftUI",
              "duration_seconds": 4.5,
              "trace_relpath": "traces/swiftui/open-recent-window.trace",
              "exit_status": 0,
              "end_reason": "completed"
            },
            {
              "scenario": "offline-cached-open",
              "template": "Allocations",
              "duration_seconds": 3.0,
              "trace_relpath": "traces/allocations/offline-cached-open.trace",
              "exit_status": 0,
              "end_reason": "completed"
            }
          ]
        }
        """
        try writeJSON(manifest, to: runDir.appendingPathComponent("manifest.json"))

        let swiftuiMetrics = """
        {
          "swiftui_updates": {"total_count": 1234, "body_update_count": 100, "duration_ms_p95": 12.5, "duration_ns_max": 25000000},
          "swiftui_update_groups": {"duration_ms_p95": 8.0, "label_counts": {"Dashboard": 50, "Sidebar": 10}},
          "swiftui_causes": {"source_node_counts": {"DashboardView": 30}},
          "hitches": {"count": 1},
          "potential_hangs": {"count": 0}
        }
        """
        try writeJSON(
            swiftuiMetrics,
            to: runDir.appendingPathComponent("metrics/open-recent-window/swiftui.json")
        )

        let allocationsMetrics = """
        {
          "allocations": {
            "summary_rows": {
              "All Heap & Anonymous VM": {"persistent_bytes": 250000, "total_bytes": 500000},
              "All VM Regions": {"persistent_bytes": 60000, "total_bytes": 120000}
            }
          }
        }
        """
        try writeJSON(
            allocationsMetrics,
            to: runDir.appendingPathComponent("metrics/offline-cached-open/allocations.json")
        )
    }

    func testSummarizeWritesJSONAndCSV() throws {
        try seedRun()
        let manifest = try Summarizer.summarize(runDir: runDir)

        XCTAssertEqual(manifest.label, "step3")
        XCTAssertEqual(manifest.captures.count, 2)
        XCTAssertNotNil(manifest.captures[0].metrics)

        let summaryURL = runDir.appendingPathComponent("summary.json")
        let csvURL = runDir.appendingPathComponent("summary.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))

        let summaryData = try Data(contentsOf: summaryURL)
        let summaryString = try XCTUnwrap(String(data: summaryData, encoding: .utf8))
        XCTAssertTrue(summaryString.contains("\"label\" : \"step3\""))
        XCTAssertTrue(summaryString.contains("\"total_count\" : 1234"))

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], Summarizer.csvHeader.joined(separator: ","))
        XCTAssertTrue(lines[1].hasPrefix("open-recent-window,SwiftUI,4.5,0,completed,1234,100,12.5,25,8,"))
        XCTAssertTrue(lines[2].hasPrefix("offline-cached-open,Allocations,3,0,completed,,,,,,,,,,250000,500000,60000,120000"))
    }

    func testSummarizeFailsWhenManifestMissing() {
        XCTAssertThrowsError(try Summarizer.summarize(runDir: runDir)) { error in
            guard let failure = error as? Summarizer.Failure else {
                XCTFail("expected Summarizer.Failure, got \(error)")
                return
            }
            XCTAssertTrue(failure.message.contains("manifest.json"))
        }
    }

    func testSummarizePreservesWarningsWhenMetricsFileMissing() throws {
        try seedRun()
        let metricsURL = runDir.appendingPathComponent("metrics/open-recent-window/swiftui.json")
        try FileManager.default.removeItem(at: metricsURL)
        let manifest = try Summarizer.summarize(runDir: runDir)

        XCTAssertEqual(manifest.captures.count, 2)
        XCTAssertNil(manifest.captures[0].metrics)
        XCTAssertEqual(manifest.captures[0].warnings?.count, 1)
        XCTAssertTrue(manifest.captures[0].warnings?.first?.contains("metrics file missing") == true)
        XCTAssertEqual(manifest.warnings?.count, 1)
    }

    func testTemplateSlugMatchesPython() {
        XCTAssertEqual(Summarizer.templateSlug("SwiftUI"), "swiftui")
        XCTAssertEqual(Summarizer.templateSlug("Allocations"), "allocations")
        XCTAssertEqual(Summarizer.templateSlug("Time Profiler"), "time-profiler")
    }
}
