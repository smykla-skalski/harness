import XCTest
@testable import HarnessMonitorPerfCore

final class BudgetEnforcerTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    func testPassingSummaryProducesNoFailures() throws {
        let data = try fixtureData("summary-pass")
        XCTAssertTrue(BudgetEnforcer.collectFailures(summaryJSON: data).isEmpty)
        XCTAssertNoThrow(try BudgetEnforcer.enforce(summaryJSON: data))
    }

    func testSwiftUIBudgetsFlagAllOverages() throws {
        let data = try fixtureData("summary-fail-swiftui")
        let failures = BudgetEnforcer.collectFailures(summaryJSON: data)
        XCTAssertEqual(failures.count, 5)
        XCTAssertTrue(failures.contains { $0.contains("total_updates exceeded") })
        XCTAssertTrue(failures.contains { $0.contains("body_updates exceeded") })
        XCTAssertTrue(failures.contains { $0.contains("max_update_group_ms exceeded") })
        XCTAssertTrue(failures.contains { $0.contains("hitches exceeded") })
        XCTAssertTrue(failures.contains { $0.contains("potential_hangs exceeded") })
        XCTAssertThrowsError(try BudgetEnforcer.enforce(summaryJSON: data))
    }

    func testAllocationsBudgetFlagsHeapOverage() throws {
        let data = try fixtureData("summary-fail-allocations")
        let failures = BudgetEnforcer.collectFailures(summaryJSON: data)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("offline-cached-open Allocations") == true)
    }

    func testUnknownScenarioFallsBackToDefaultSwiftUIBudget() {
        let payload: [String: Any] = [
            "captures": [[
                "scenario": "brand-new-scenario",
                "template": "SwiftUI",
                "metrics": [
                    "swiftui_updates": ["total_count": 40_000, "body_update_count": 100],
                    "swiftui_update_groups": ["duration_ns_max": 10_000_000],
                    "hitches": ["count": 0],
                    "potential_hangs": ["count": 0],
                ],
            ]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let failures = BudgetEnforcer.collectFailures(summaryJSON: data)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("total_updates") == true)
    }

    func testUnknownAllocationsScenarioIsSkipped() {
        let payload: [String: Any] = [
            "captures": [[
                "scenario": "uncovered-allocations",
                "template": "Allocations",
                "metrics": [
                    "allocations": [
                        "summary_rows": [
                            "All Heap Allocations": ["total_bytes": 999_999_999],
                        ],
                    ],
                ],
            ]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        XCTAssertTrue(BudgetEnforcer.collectFailures(summaryJSON: data).isEmpty)
    }

    func testCatalogParityWithPython() {
        XCTAssertEqual(Budgets.swiftUIByScenario.keys.sorted(), [
            "launch-dashboard",
            "refresh-and-search",
            "select-session-cockpit",
            "timeline-burst",
        ])
        XCTAssertEqual(Budgets.allocationsByScenario.keys.sorted(), [
            "offline-cached-open",
            "settings-backdrop-cycle",
            "settings-background-cycle",
        ])
        XCTAssertEqual(Budgets.defaultSwiftUI.totalUpdates, 35_000)
        XCTAssertEqual(Budgets.retainedRunSizeKiB, 10_240)
    }
}
