import XCTest
@testable import HarnessMonitorPerfCore

final class RecapTests: XCTestCase {
    private func decode(_ payload: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
    }

    func testSwiftUIRecapIncludesAllMetricsAndTopOffenders() throws {
        let summary = try decode("""
        {
          "label": "perf",
          "created_at_utc": "2026-04-25T00:00:00Z",
          "git": {"commit": "abcdef0", "dirty": false},
          "captures": [
            {
              "scenario": "open-recent-window",
              "template": "SwiftUI",
              "launch_metrics": {
                "app_init_to_ready_ms": 350,
                "measured_from": "app_init",
                "state_label": "running",
                "window_id": "open-recent",
                "includes_bootstrap_in_scenario_measurement": true
              },
              "metrics": {
                "swiftui_updates": {"total_count": 1234, "body_update_count": 100, "duration_ms_p95": 12.5, "duration_ns_max": 25000000},
                "time_profile": {"sample_count": 42, "app_owned_frame_count": 37, "fallback_symbolic_frame_count": 5},
                "hitches": {"count": 1},
                "potential_hangs": {"count": 0},
                "top_offenders": [
                  {"description": "Dashboard body", "view_name": "Dashboard", "duration_ms": 4.5, "count": 7},
                  {"description": "Sidebar body", "view_name": "Sidebar", "duration_ms": 1.0, "count": 3}
                ]
              }
            }
          ]
        }
        """)
        let text = Recap.render(summary: summary, comparison: nil, topCount: 5)
        XCTAssertTrue(text.contains("- label=perf"))
        XCTAssertTrue(text.contains("- run_id=2026-04-25T00:00:00Z"))
        XCTAssertTrue(text.contains("- commit=abcdef0 dirty=False"))
        XCTAssertTrue(text.contains("open-recent-window [SwiftUI]: launch_ms=350.0000"))
        XCTAssertTrue(text.contains("total_updates=1234 body_updates=100"))
        XCTAssertTrue(text.contains("p95_ms=12.5000"))
        XCTAssertTrue(text.contains("max_ms=25.0000"))
        XCTAssertTrue(text.contains("time_profile_sample_count=42"))
        XCTAssertTrue(text.contains("time_profile_app_owned_frame_count=37"))
        XCTAssertTrue(text.contains("time_profile_fallback_symbolic_frame_count=5"))
        XCTAssertTrue(text.contains("hitches=1 potential_hangs=0"))
        XCTAssertTrue(text.contains("1. Dashboard body | Dashboard | duration_ms=4.5000 | count=7"))
        XCTAssertTrue(text.contains("2. Sidebar body | Sidebar | duration_ms=1.0000 | count=3"))
    }

    func testRecapAppendsDeltaWhenComparisonProvided() throws {
        let summary = try decode("""
        {
          "label": "current",
          "captures": [{
            "scenario": "open-recent-window",
            "template": "SwiftUI",
            "metrics": {
              "swiftui_updates": {"total_count": 1100, "body_update_count": 110, "duration_ms_p95": 11.0, "duration_ns_max": 15000000},
              "time_profile": {"sample_count": 140, "app_owned_frame_count": 100, "fallback_symbolic_frame_count": 40},
              "hitches": {"count": 1},
              "potential_hangs": {"count": 0}
            }
          }]
        }
        """)
        let comparison = try decode("""
        {"comparisons": [{
          "scenario": "open-recent-window",
          "template": "SwiftUI",
          "shared_metrics": {
            "launch_app_init_to_ready_ms": {"baseline": 310, "current": 350, "delta": 40},
            "time_profile_sample_count": {"baseline": 120, "current": 140, "delta": 20},
            "time_profile_app_owned_frame_count": {"baseline": 90, "current": 100, "delta": 10},
            "time_profile_fallback_symbolic_frame_count": {"baseline": 30, "current": 40, "delta": 10}
          },
          "metrics": {
            "total_updates": {"baseline": 1000, "current": 1100, "delta": 100},
            "body_updates": {"baseline": 100, "current": 110, "delta": 10},
            "hitches": {"baseline": 0, "current": 1, "delta": 1},
            "potential_hangs": {"baseline": 0, "current": 0, "delta": 0}
          }
        }]}
        """)
        let text = Recap.render(summary: summary, comparison: comparison, topCount: 0)
        XCTAssertTrue(text.contains("d_launch_ms=40"))
        XCTAssertTrue(text.contains("d_time_profile_sample_count=20"))
        XCTAssertTrue(text.contains("d_time_profile_app_owned_frame_count=10"))
        XCTAssertTrue(text.contains("d_time_profile_fallback_symbolic_frame_count=10"))
        XCTAssertTrue(text.contains("d_total_updates=100"))
        XCTAssertTrue(text.contains("d_body_updates=10"))
        XCTAssertTrue(text.contains("d_hitches=1"))
    }

    func testAllocationsRecapIncludesSelectedCategories() throws {
        let summary = try decode("""
        {
            "captures": [{
              "scenario": "offline-cached-open",
              "template": "Allocations",
              "launch_metrics": {
                "app_init_to_ready_ms": 420,
                "measured_from": "app_init",
                "state_label": "running",
                "window_id": "open-recent",
                "includes_bootstrap_in_scenario_measurement": false
              },
              "metrics": {"allocations": {"summary_rows": {
                "All Heap & Anonymous VM": {"persistent_bytes": 100, "total_bytes": 200},
                "All VM Regions": {"persistent_bytes": 50, "total_bytes": 80}
              }}}
            }]
        }
        """)
        let text = Recap.render(summary: summary, comparison: nil, topCount: 0)
        XCTAssertTrue(text.contains("offline-cached-open [Allocations]:"))
        XCTAssertTrue(text.contains("launch_ms=420.0000"))
        XCTAssertTrue(text.contains("All Heap & Anonymous VM: persistent_bytes=100 total_bytes=200"))
        XCTAssertTrue(text.contains("All VM Regions: persistent_bytes=50 total_bytes=80"))
    }
}
