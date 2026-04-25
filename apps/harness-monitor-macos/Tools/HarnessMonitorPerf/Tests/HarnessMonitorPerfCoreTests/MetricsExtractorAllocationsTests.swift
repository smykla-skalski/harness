import XCTest
@testable import HarnessMonitorPerfCore

final class MetricsExtractorAllocationsTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name, withExtension: "xml", subdirectory: "Fixtures/xml"
            )
        )
        return try Data(contentsOf: url)
    }

    func testAllocationsStatisticsParsesAllRowsAndOrdersOffenders() throws {
        let data = try fixtureData("allocations-statistics-minimal")
        let result = try MetricsExtractor.parseAllocationsStatistics(data: data)

        // 5 valid rows (last row has empty category and is skipped).
        XCTAssertEqual(result.allocations.categoryCount, 5)

        // The four canonical summary categories must all be present even when their stats
        // dictionary is non-empty.
        XCTAssertEqual(
            result.allocations.summaryRows.keys.sorted(),
            MetricsExtractor.allocationsSummaryCategories.sorted()
        )

        let heap = try XCTUnwrap(result.allocations.summaryRows["All Heap Allocations"])
        XCTAssertEqual(heap["persistent_bytes"], 350_000_000)
        XCTAssertEqual(heap["total_bytes"], 600_000_000)
        XCTAssertEqual(heap["count_events"], 80_000)

        // Offenders sorted by persistent_bytes desc.
        XCTAssertEqual(result.topOffenders.first?.category, "All Heap & Anonymous VM")
        XCTAssertEqual(result.topOffenders.first?.persistentBytes, 500_000_000)
        XCTAssertEqual(result.topOffenders.last?.category, "Malloc 16 Bytes")
    }

    func testEmptyCategoryRowsAreSkipped() throws {
        let xml = """
        <?xml version="1.0"?>
        <root>
            <row category="" persistent_bytes="100"/>
            <row category="Real" persistent_bytes="50" total_bytes="200" count_events="3"/>
        </root>
        """
        let result = try MetricsExtractor.parseAllocationsStatistics(data: Data(xml.utf8))
        XCTAssertEqual(result.allocations.categoryCount, 1)
        XCTAssertEqual(result.topOffenders.count, 1)
        XCTAssertEqual(result.topOffenders[0].category, "Real")
        XCTAssertEqual(result.topOffenders[0].totalBytes, 200)
        XCTAssertEqual(result.topOffenders[0].countEvents, 3)
    }

    func testHyphenAttributesNormalisedToUnderscore() throws {
        let xml = """
        <?xml version="1.0"?>
        <root>
            <row category="X" total-bytes="100" persistent-bytes="50" count-events="1"/>
        </root>
        """
        let result = try MetricsExtractor.parseAllocationsStatistics(data: Data(xml.utf8))
        XCTAssertEqual(result.topOffenders.first?.totalBytes, 100)
        XCTAssertEqual(result.topOffenders.first?.persistentBytes, 50)
        XCTAssertEqual(result.topOffenders.first?.countEvents, 1)
    }
}
