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
              "scenario": "launch-dashboard",
              "template": "SwiftUI",
              "metrics": {
                "swiftui_updates": {"total_count": 1234, "body_update_count": 100, "duration_ms_p95": 12.5, "duration_ns_max": 25000000},
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
        XCTAssertTrue(text.contains("launch-dashboard [SwiftUI]: total_updates=1234 body_updates=100"))
        XCTAssertTrue(text.contains("p95_ms=12.5000"))
        XCTAssertTrue(text.contains("max_ms=25.0000"))
        XCTAssertTrue(text.contains("hitches=1 potential_hangs=0"))
        XCTAssertTrue(text.contains("1. Dashboard body | Dashboard | duration_ms=4.5000 | count=7"))
        XCTAssertTrue(text.contains("2. Sidebar body | Sidebar | duration_ms=1.0000 | count=3"))
    }

    func testRecapAppendsDeltaWhenComparisonProvided() throws {
        let summary = try decode("""
        {
          "label": "current",
          "captures": [{
            "scenario": "launch-dashboard",
            "template": "SwiftUI",
            "metrics": {
              "swiftui_updates": {"total_count": 1100, "body_update_count": 110, "duration_ms_p95": 11.0, "duration_ns_max": 15000000},
              "hitches": {"count": 1},
              "potential_hangs": {"count": 0}
            }
          }]
        }
        """)
        let comparison = try decode("""
        {"comparisons": [{
          "scenario": "launch-dashboard",
          "template": "SwiftUI",
          "metrics": {
            "total_updates": {"baseline": 1000, "current": 1100, "delta": 100},
            "body_updates": {"baseline": 100, "current": 110, "delta": 10},
            "hitches": {"baseline": 0, "current": 1, "delta": 1},
            "potential_hangs": {"baseline": 0, "current": 0, "delta": 0}
          }
        }]}
        """)
        let text = Recap.render(summary: summary, comparison: comparison, topCount: 0)
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
            "metrics": {"allocations": {"summary_rows": {
              "All Heap & Anonymous VM": {"persistent_bytes": 100, "total_bytes": 200},
              "All VM Regions": {"persistent_bytes": 50, "total_bytes": 80}
            }}}
          }]
        }
        """)
        let text = Recap.render(summary: summary, comparison: nil, topCount: 0)
        XCTAssertTrue(text.contains("offline-cached-open [Allocations]:"))
        XCTAssertTrue(text.contains("All Heap & Anonymous VM: persistent_bytes=100 total_bytes=200"))
        XCTAssertTrue(text.contains("All VM Regions: persistent_bytes=50 total_bytes=80"))
    }
}
