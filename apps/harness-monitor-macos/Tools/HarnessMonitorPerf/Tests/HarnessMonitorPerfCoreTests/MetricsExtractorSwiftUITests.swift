import XCTest
@testable import HarnessMonitorPerfCore

final class MetricsExtractorSwiftUITests: XCTestCase {
    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(
                forResource: name, withExtension: "xml", subdirectory: "Fixtures/xml"
            )
        )
    }

    func testUpdateGroupsAggregatesDurationAndLabels() throws {
        let document = try XctraceQueryDocument(path: try fixtureURL("swiftui-update-groups-minimal"))
        let result = MetricsExtractor.parseSwiftUIUpdateGroups(document)

        XCTAssertEqual(result.summary.totalCount, 3)
        XCTAssertEqual(result.summary.durationNsTotal, 4_500_000)
        XCTAssertEqual(result.summary.durationNsMax, 3_000_000)
        XCTAssertEqual(result.summary.durationMsP95, 3.0, accuracy: 0.0001)
        XCTAssertEqual(result.summary.labelCounts, ["Dashboard": 2, "Sidebar": 1])

        XCTAssertEqual(result.topGroups.count, 2)
        XCTAssertEqual(result.topGroups[0].label, "Dashboard")
        XCTAssertEqual(result.topGroups[0].count, 2)
        XCTAssertEqual(result.topGroups[0].durationNs, 4_000_000)
        XCTAssertEqual(result.topGroups[0].durationMs, 4.0, accuracy: 0.0001)
        XCTAssertEqual(result.topGroups[1].label, "Sidebar")
    }

    func testCausesGroupsBySourceDestinationLabel() throws {
        let document = try XctraceQueryDocument(path: try fixtureURL("swiftui-causes-minimal"))
        let result = MetricsExtractor.parseSwiftUICauses(document)

        XCTAssertEqual(result.summary.totalCount, 3)
        XCTAssertEqual(result.summary.labelCounts, ["@State": 2, "@Binding": 1])
        XCTAssertEqual(result.summary.sourceNodeCounts, ["DashboardView": 2, "ToolbarView": 1])
        XCTAssertEqual(result.summary.destinationNodeCounts, ["SidebarRow": 3])
        // <unknown> entries excluded from value-type and changed-properties counters
        XCTAssertEqual(result.summary.valueTypeCounts, ["Int": 2])
        XCTAssertEqual(result.summary.changedPropertyCounts, ["selectedID": 2])

        XCTAssertEqual(result.topCauses.count, 2)
        let stateCause = try XCTUnwrap(result.topCauses.first { $0.label == "@State" })
        XCTAssertEqual(stateCause.sourceNode, "DashboardView")
        XCTAssertEqual(stateCause.destinationNode, "SidebarRow")
        XCTAssertEqual(stateCause.count, 2)
    }

    func testEventTableCountsDurationsAndTopLabels() throws {
        let document = try XctraceQueryDocument(path: try fixtureURL("hitches-minimal"))
        let result = MetricsExtractor.parseEventTable(document)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.durationNsTotal, 350_000_000)
        XCTAssertEqual(result.durationNsMax, 200_000_000)
        XCTAssertEqual(result.topLabels.count, 2)
        XCTAssertEqual(result.topLabels[0].label, "Frame drop on Dashboard")
        XCTAssertEqual(result.topLabels[0].count, 2)
        XCTAssertEqual(result.topLabels[1].label, "Animation hitch")
    }

    func testTimeProfilePrefersAppOwnedFramesAndSkipsHexAddresses() throws {
        let document = try XctraceQueryDocument(path: try fixtureURL("time-profile-minimal"))
        let result = MetricsExtractor.parseTimeProfile(document)

        XCTAssertEqual(result.summary.sampleCount, 3)
        XCTAssertEqual(result.summary.appOwnedFrameCount, 2)
        XCTAssertEqual(result.summary.fallbackSymbolicFrameCount, 3)
        XCTAssertEqual(result.topFrames.count, 1)
        XCTAssertEqual(result.topFrames[0].name, "DashboardView.body")
        XCTAssertEqual(result.topFrames[0].samples, 2)
    }
}
