import XCTest
@testable import HarnessMonitorPerfCore

final class MetricsExtractorTests: XCTestCase {
    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(
                forResource: name, withExtension: "xml", subdirectory: "Fixtures/xml"
            )
        )
    }

    func testTOCExposesSchemasAndAllocationDetails() throws {
        let toc = try XctraceTOC(path: try fixtureURL("toc-minimal"))
        XCTAssertEqual(toc.availableSchemas(), [
            "swiftui-updates", "swiftui-update-groups", "hitches", "potential-hangs", "time-profile",
        ])
        XCTAssertEqual(toc.availableAllocationDetails(), ["Statistics"])
    }

    func testQueryDocumentResolvesRefChain() throws {
        let document = try XctraceQueryDocument(path: try fixtureURL("swiftui-updates-minimal"))
        let rows = document.rows
        XCTAssertEqual(rows.count, 4)
        let firstRecord = document.record(for: rows[0])
        XCTAssertEqual(firstRecord["duration"], "500000")
        XCTAssertEqual(firstRecord["update-type"], "body")
        let secondRecord = document.record(for: rows[1])
        // ref=8 → DashboardView (resolved through dereference)
        XCTAssertEqual(secondRecord["view-name"], "DashboardView")
        XCTAssertEqual(secondRecord["update-type"], "body")
    }

    func testSwiftUIUpdatesAggregation() throws {
        let document = try XctraceQueryDocument(path: try fixtureURL("swiftui-updates-minimal"))
        let result = MetricsExtractor.parseSwiftUIUpdates(document)

        XCTAssertEqual(result.summary.totalCount, 4)
        XCTAssertEqual(result.summary.bodyUpdateCount, 2)
        XCTAssertEqual(result.summary.durationNsTotal, 2_650_000)
        XCTAssertEqual(result.summary.durationNsMax, 2_000_000)
        XCTAssertEqual(result.summary.durationMsP95, 2.0, accuracy: 0.0001)
        XCTAssertEqual(result.summary.allocationsTotal, 9)
        XCTAssertEqual(result.summary.updateTypeCounts, ["body": 2, "layout": 2])
        XCTAssertEqual(result.summary.severityCounts, ["info": 3, "warning": 1])
        XCTAssertEqual(result.summary.categoryCounts, ["render": 3, "layout": 1])

        XCTAssertEqual(result.topOffenders.count, 2)
        XCTAssertEqual(result.topOffenders[0].description, "DashboardView body")
        XCTAssertEqual(result.topOffenders[0].count, 2)
        XCTAssertEqual(result.topOffenders[0].durationNs, 2_500_000)
        XCTAssertEqual(result.topOffenders[0].durationMs, 2.5, accuracy: 0.0001)
        XCTAssertEqual(result.topOffenders[0].allocations, 8)
        XCTAssertEqual(result.topOffenders[1].description, "SidebarRow")
        XCTAssertEqual(result.topOffenders[1].durationNs, 150_000)
    }

    func testParseIntStripsCommasAndIgnoresBlanks() {
        XCTAssertEqual(MetricsExtractor.parseInt("1,234"), 1234)
        XCTAssertEqual(MetricsExtractor.parseInt("  42  "), 42)
        XCTAssertNil(MetricsExtractor.parseInt(""))
        XCTAssertNil(MetricsExtractor.parseInt(nil))
        XCTAssertEqual(MetricsExtractor.parseInt("3.14"), 3)
    }

    func testNormalizeReplacesBlanksWithUnknown() {
        XCTAssertEqual(MetricsExtractor.normalize(nil), "<unknown>")
        XCTAssertEqual(MetricsExtractor.normalize(""), "<unknown>")
        XCTAssertEqual(MetricsExtractor.normalize("  hello  "), "hello")
    }

    func testPercentileMatchesPythonFormula() {
        // python: rank = max(0, ceil(pct/100 * n) - 1)
        XCTAssertEqual(MetricsExtractor.percentile([], percent: 95), 0)
        XCTAssertEqual(MetricsExtractor.percentile([10, 20, 30, 40], percent: 95), 40)
        XCTAssertEqual(MetricsExtractor.percentile([10, 20, 30, 40], percent: 50), 20)
        XCTAssertEqual(MetricsExtractor.percentile([5], percent: 99), 5)
    }

    func testNsToMsRoundsToFourDecimals() {
        XCTAssertEqual(MetricsExtractor.nsToMs(1_500_000), 1.5)
        XCTAssertEqual(MetricsExtractor.nsToMs(0), 0)
        XCTAssertEqual(MetricsExtractor.nsToMs(1_234), 0.0012)
    }
}
