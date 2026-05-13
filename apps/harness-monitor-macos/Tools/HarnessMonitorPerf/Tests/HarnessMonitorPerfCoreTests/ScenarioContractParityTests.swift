import Foundation
import XCTest
@testable import HarnessMonitorPerfCore

final class ScenarioContractParityTests: XCTestCase {
    func testScenarioCatalogMatchesAppPerfEnum() throws {
        let rawValues = try appPerfScenarioRawValues()
        XCTAssertEqual(rawValues, ScenarioCatalog.all)
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
    }

    func testCatalogPartitionsRemainAligned() {
        XCTAssertEqual(Set(ScenarioCatalog.all), ScenarioCatalog.swiftUI.union(ScenarioCatalog.allocations))
        XCTAssertEqual(Set(Budgets.swiftUIByScenario.keys), ScenarioCatalog.swiftUI)
        XCTAssertEqual(Set(Budgets.allocationsByScenario.keys), ScenarioCatalog.allocations)
        XCTAssertEqual(Set(ManifestBuilder.defaultTemplates.swiftui), ScenarioCatalog.swiftUI)
        XCTAssertEqual(Set(ManifestBuilder.defaultTemplates.allocations), ScenarioCatalog.allocations)
    }

    private func appPerfScenarioRawValues() throws -> [String] {
        let sourceURL = appRootURL
            .appendingPathComponent("Sources/HarnessMonitor/App/HarnessMonitorPerfScenario.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"case\s+\w+\s*=\s*"([^"]+)""#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges == 2,
                let rawValueRange = Range(match.range(at: 1), in: source)
            else {
                return nil
            }
            return String(source[rawValueRange])
        }
    }

    private var appRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
