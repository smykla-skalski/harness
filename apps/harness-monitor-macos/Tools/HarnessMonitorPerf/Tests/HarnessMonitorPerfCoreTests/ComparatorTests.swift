import XCTest
@testable import HarnessMonitorPerfCore

final class ComparatorTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("perf-comparator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func writeSummary(_ payload: String, name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(payload.utf8).write(to: url, options: .atomic)
        return url
    }

    private static let baselinePayload = """
        {
          "label": "baseline",
          "created_at_utc": "2026-04-01T00:00:00Z",
          "captures": [
            {
              "scenario": "open-recent-window",
              "template": "SwiftUI",
              "launch_metrics": {
                "app_init_to_ready_ms": 320,
                "measured_from": "app_init",
                "state_label": "running",
                "window_id": "open-recent",
                "includes_bootstrap_in_scenario_measurement": true
              },
               "metric_tiers": {
                 "hard_budget": ["launch_app_init_to_ready_ms", "total_updates", "body_updates", "max_update_group_ms", "hitches", "potential_hangs"],
                 "investigative": ["p95_update_ms", "max_update_ms", "update_group_p95_ms", "top_frames"]
               },
               "app_trace": {
                 "relpath": "app-traces/open-recent-window/swiftui/app-trace.jsonl",
                 "event_count": 2,
                 "components": [
                   {"component": "perf.scenario", "count": 2}
                 ],
                 "ordered_steps": ["route.agents", "search.present"]
               },
               "findings": [
                 {"key": "cause:state:dashboardview:sidebarrow", "category": "swiftui-cause", "headline": "@State: DashboardView -> SidebarRow", "count": 2}
               ],
              "metrics": {
                "swiftui_updates": {"total_count": 10000, "body_update_count": 1000, "duration_ms_p95": 10.0, "duration_ns_max": 12000000},
                "swiftui_update_groups": {"duration_ms_p95": 8.0, "duration_ns_max": 20000000},
                "hitches": {"count": 0},
                "potential_hangs": {"count": 0},
                "top_frames": [{"name": "DashboardView.body", "samples": 100}]
          }
        },
        {
          "scenario": "offline-cached-open",
          "template": "Allocations",
          "metrics": {
            "allocations": {
              "summary_rows": {
                "All Heap & Anonymous VM": {"persistent_bytes": 100, "total_bytes": 200, "count_events": 3},
                "All Heap Allocations": {"persistent_bytes": 50, "total_bytes": 100, "count_events": 1}
              }
            }
          }
        },
        {
          "scenario": "baseline-only-scenario",
          "template": "SwiftUI",
          "warnings": ["metrics file missing: /tmp/baseline-only.json"]
        }
      ]
    }
    """

    private static let currentPayload = """
        {
          "label": "current",
          "created_at_utc": "2026-04-25T00:00:00Z",
          "captures": [
            {
              "scenario": "open-recent-window",
              "template": "SwiftUI",
              "launch_metrics": {
                "app_init_to_ready_ms": 360,
                "measured_from": "app_init",
                "state_label": "running",
                "window_id": "open-recent",
                "includes_bootstrap_in_scenario_measurement": true
              },
               "metric_tiers": {
                 "hard_budget": ["launch_app_init_to_ready_ms", "total_updates", "body_updates", "max_update_group_ms", "hitches", "potential_hangs"],
                 "investigative": ["p95_update_ms", "max_update_ms", "update_group_p95_ms", "top_frames"]
               },
               "app_trace": {
                 "relpath": "app-traces/open-recent-window/swiftui/app-trace.jsonl",
                 "event_count": 3,
                 "components": [
                   {"component": "perf.scenario", "count": 3}
                 ],
                 "ordered_steps": ["route.agents", "search.present", "route.tasks"]
               },
               "findings": [
                 {"key": "cause:state:dashboardview:sidebarrow", "category": "swiftui-cause", "headline": "@State: DashboardView -> SidebarRow", "count": 2},
                 {"key": "cause:creation:viewcreation:preferencelist", "category": "swiftui-cause", "headline": "Creation: View Creation -> Preference List", "count": 3},
                 {"key": "update-group:transaction-for-unknown-action:agentdetailsection", "category": "swiftui-update-group", "headline": "Transaction for unknown action via AgentDetailSection.debouncePersist(value:key:defaults:)", "count": 5}
               ],
               "metrics": {
                 "swiftui_updates": {"total_count": 11000, "body_update_count": 1100, "duration_ms_p95": 11.5, "duration_ns_max": 15000000},
                 "swiftui_update_groups": {"duration_ms_p95": 9.0, "duration_ns_max": 24000000},
                "hitches": {"count": 1},
                "potential_hangs": {"count": 0},
                "top_frames": [{"name": "DashboardView.body", "samples": 110}, {"name": "SidebarRow.body", "samples": 30}]
          }
        },
        {
          "scenario": "offline-cached-open",
          "template": "Allocations",
          "metrics": {
            "allocations": {
              "summary_rows": {
                "All Heap & Anonymous VM": {"persistent_bytes": 150, "total_bytes": 300, "count_events": 5},
                "All Heap Allocations": {"persistent_bytes": 60, "total_bytes": 120, "count_events": 2}
              }
            }
          }
        },
        {
          "scenario": "scenario-not-in-baseline",
          "template": "SwiftUI",
          "metrics": {"swiftui_updates": {"total_count": 0}}
        }
      ]
    }
    """

    func testCompareWritesJSONAndMarkdown() throws {
        let baseline = try writeSummary(Self.baselinePayload, name: "baseline.json")
        let current = try writeSummary(Self.currentPayload, name: "current.json")
        let outputDir = workDir.appendingPathComponent("out")

        let comparison = try Comparator.compare(.init(
            current: current, baseline: baseline, outputDir: outputDir
        ))

        XCTAssertEqual(comparison.currentLabel, "current")
        XCTAssertEqual(comparison.baselineLabel, "baseline")
        // Only overlapping (scenario, template) pairs survive: 2 captures.
        XCTAssertEqual(comparison.comparisons.count, 2)
        XCTAssertEqual(
            comparison.missingFromCurrent,
            [
                .init(
                    scenario: "baseline-only-scenario",
                    template: "SwiftUI",
                    reason: "metrics file missing: /tmp/baseline-only.json"
                ),
            ]
        )
        XCTAssertEqual(
            comparison.missingFromBaseline,
            [
                .init(
                    scenario: "scenario-not-in-baseline",
                    template: "SwiftUI",
                    reason: nil
                ),
            ]
        )

        let swiftui = try XCTUnwrap(comparison.comparisons.first { $0.template == "SwiftUI" })
        guard case .swiftUI(let metrics) = swiftui.metrics else {
            return XCTFail("expected SwiftUI metrics block")
        }
        XCTAssertEqual(metrics["total_updates"]?.delta.description, "1000")
        XCTAssertEqual(metrics["hitches"]?.delta.description, "1")
        XCTAssertEqual(metrics["p95_update_ms"]?.delta.description, "1.5")
        XCTAssertEqual(metrics["max_update_group_ms"]?.delta.description, "4")
        XCTAssertEqual(swiftui.topFrames?.current.count, 2)
        XCTAssertEqual(swiftui.topFrames?.current.first?.name, "DashboardView.body")
        XCTAssertEqual(
            swiftui.sharedMetrics?[MetricName.launchAppInitToReadyMs]?.delta.description,
            "40"
        )
        XCTAssertEqual(swiftui.appTrace?.baseline?.eventCount, 2)
        XCTAssertEqual(swiftui.appTrace?.current?.eventCount, 3)
        XCTAssertEqual(swiftui.appTrace?.newSteps, ["route.tasks"])
        XCTAssertEqual(swiftui.appTrace?.resolvedSteps, [])
        XCTAssertEqual(swiftui.newFindings?.count, 2)
        XCTAssertEqual(
            swiftui.newFindings?.first?.category,
            "swiftui-update-group"
        )
        XCTAssertEqual(swiftui.newFindings?.dropFirst().first?.category, "swiftui-cause")

        let allocations = try XCTUnwrap(comparison.comparisons.first { $0.template == "Allocations" })
        guard case .allocations(let byCategory) = allocations.metrics else {
            return XCTFail("expected allocations block")
        }
        XCTAssertEqual(byCategory["All Heap & Anonymous VM"]?["persistent_bytes"]?.delta.description, "50")
        XCTAssertEqual(byCategory["All VM Regions"]?["persistent_bytes"]?.delta.description, "0")

        // Outputs on disk.
        let json = try Data(contentsOf: outputDir.appendingPathComponent("comparison.json"))
        let jsonString = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertTrue(jsonString.contains("\"baseline_label\" : \"baseline\""))
        XCTAssertTrue(jsonString.contains("\"app_trace\""))
        let decoded = try JSONDecoder().decode(Comparator.Comparison.self, from: json)
        let decodedSwiftUI = try XCTUnwrap(decoded.comparisons.first { $0.template == "SwiftUI" })
        XCTAssertEqual(decodedSwiftUI.appTrace?.current?.orderedSteps.last, "route.tasks")

        let markdown = try String(contentsOf: outputDir.appendingPathComponent("comparison.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Instruments Comparison: baseline -> current"))
        XCTAssertTrue(markdown.contains("## Missing from current"))
        XCTAssertTrue(markdown.contains("## Missing from baseline"))
        XCTAssertTrue(markdown.contains("## open-recent-window (SwiftUI)"))
        XCTAssertTrue(markdown.contains("### Hard budget metrics"))
        XCTAssertTrue(markdown.contains("| launch_app_init_to_ready_ms | 320 | 360 | 40 |"))
        XCTAssertTrue(markdown.contains("| total_updates | 10000 | 11000 | 1000 |"))
        XCTAssertTrue(markdown.contains("| All Heap Allocations | total_bytes | 100 | 120 | 20 |"))
        XCTAssertTrue(markdown.contains("Baseline hot frames: DashboardView.body"))
        XCTAssertTrue(markdown.contains("### App trace"))
        XCTAssertTrue(markdown.contains("Baseline ordered steps: route.agents -> search.present"))
        XCTAssertTrue(
            markdown.contains(
                "Current ordered steps: route.agents -> search.present -> route.tasks"
            )
        )
        XCTAssertTrue(markdown.contains("New steps: route.tasks"))
        XCTAssertTrue(markdown.contains("### New findings"))
        XCTAssertTrue(markdown.contains("Transaction for unknown action via AgentDetailSection.debouncePersist"))
        let updateGroupIndex = try XCTUnwrap(
            markdown.range(
                of: "Transaction for unknown action via AgentDetailSection.debouncePersist"
            )?.lowerBound
        )
        let causeIndex = try XCTUnwrap(
            markdown.range(
                of: "Creation: View Creation -> Preference List"
            )?.lowerBound
        )
        XCTAssertLessThan(updateGroupIndex, causeIndex)
    }

    func testCompareAppTraceHandlesAsymmetricPresence() throws {
        let baseline = try writeSummary(
            """
            {
              "label": "baseline",
              "created_at_utc": "2026-04-01T00:00:00Z",
              "captures": [
                {
                  "scenario": "open-recent-window",
                  "template": "SwiftUI",
                  "metrics": {
                    "swiftui_updates": {"total_count": 1, "body_update_count": 1, "duration_ms_p95": 1.0, "duration_ns_max": 1000000},
                    "swiftui_update_groups": {"duration_ms_p95": 1.0, "duration_ns_max": 1000000},
                    "hitches": {"count": 0},
                    "potential_hangs": {"count": 0}
                  }
                }
              ]
            }
            """,
            name: "baseline-asymmetric.json"
        )
        let current = try writeSummary(Self.currentPayload, name: "current-asymmetric.json")
        let outputDir = workDir.appendingPathComponent("out-asymmetric")

        let comparison = try Comparator.compare(.init(
            current: current, baseline: baseline, outputDir: outputDir
        ))
        let swiftui = try XCTUnwrap(comparison.comparisons.first { $0.template == "SwiftUI" })

        XCTAssertNil(swiftui.appTrace?.baseline)
        XCTAssertEqual(swiftui.appTrace?.current?.eventCount, 3)
        XCTAssertEqual(
            swiftui.appTrace?.newSteps,
            ["route.agents", "search.present", "route.tasks"]
        )
        XCTAssertEqual(swiftui.appTrace?.resolvedSteps, [])
    }

    func testCompareWithNoOverlapEmitsExplainerInMarkdown() throws {
        let empty = """
        {"label": "x", "created_at_utc": "2026-04-25T00:00:00Z", "captures": []}
        """
        let other = """
        {"label": "y", "created_at_utc": "2026-04-25T00:00:00Z", "captures": []}
        """
        let baseline = try writeSummary(empty, name: "b.json")
        let current = try writeSummary(other, name: "c.json")
        let outputDir = workDir.appendingPathComponent("out2")

        let comparison = try Comparator.compare(.init(
            current: current, baseline: baseline, outputDir: outputDir
        ))
        XCTAssertTrue(comparison.comparisons.isEmpty)

        let markdown = try String(contentsOf: outputDir.appendingPathComponent("comparison.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("No overlapping scenario/template captures"))
    }

    func testCompareReportsCapturesWithoutMetrics() throws {
        let baseline = try writeSummary(
            """
            {
              "label": "baseline",
              "created_at_utc": "2026-04-01T00:00:00Z",
              "captures": [
                {
                  "scenario": "open-recent-window",
                  "template": "SwiftUI",
                  "warnings": ["metrics file missing: /tmp/baseline.json"]
                }
              ]
            }
            """,
            name: "baseline-missing.json"
        )
        let current = try writeSummary(Self.currentPayload, name: "current-missing.json")
        let outputDir = workDir.appendingPathComponent("out-missing")

        let comparison = try Comparator.compare(.init(
            current: current, baseline: baseline, outputDir: outputDir
        ))

        XCTAssertTrue(comparison.comparisons.isEmpty)
        XCTAssertEqual(
            comparison.baselineMissingMetrics,
            [
                .init(
                    scenario: "open-recent-window",
                    template: "SwiftUI",
                    reason: "metrics file missing: /tmp/baseline.json"
                ),
            ]
        )
        XCTAssertTrue(comparison.missingFromBaseline.contains { $0.scenario == "offline-cached-open" })
        XCTAssertTrue(comparison.missingFromBaseline.contains { $0.scenario == "scenario-not-in-baseline" })

        let markdown = try String(contentsOf: outputDir.appendingPathComponent("comparison.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Baseline captures without metrics"))
        XCTAssertTrue(markdown.contains("metrics file missing"))
    }

    func testCompareLoadsSummaryFromDirectory() throws {
        let runDir = workDir.appendingPathComponent("baseline-run")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try Data(Self.baselinePayload.utf8).write(
            to: runDir.appendingPathComponent("summary.json"), options: .atomic
        )
        let manifest = try Comparator.loadSummary(runDir)
        XCTAssertEqual(manifest.label, "baseline")
        XCTAssertEqual(manifest.captures.count, 3)
    }

    func testCompareThrowsWhenSummaryMissing() {
        XCTAssertThrowsError(try Comparator.loadSummary(workDir.appendingPathComponent("none.json")))
    }
}
