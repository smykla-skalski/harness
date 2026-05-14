import Foundation
import XCTest
@testable import HarnessMonitorPerfCore

final class ScenarioContractParityTests: XCTestCase {
    func testSharedScenarioSourceMatchesAppPerfEnumAndToolCatalog() throws {
        let sourceOfTruth = PerfScenarioDefinitions.all.map(\.id)
        let rawValues = try appPerfScenarioRawValues()

        XCTAssertEqual(sourceOfTruth, rawValues)
        XCTAssertEqual(sourceOfTruth, ScenarioCatalog.all)
        XCTAssertEqual(Set(sourceOfTruth).count, sourceOfTruth.count)
    }

    func testCatalogPartitionsRemainAligned() {
        XCTAssertEqual(Set(ScenarioCatalog.all), ScenarioCatalog.swiftUI.union(ScenarioCatalog.allocations))
        XCTAssertEqual(Set(Budgets.swiftUIByScenario.keys), ScenarioCatalog.swiftUI)
        XCTAssertEqual(Set(Budgets.allocationsByScenario.keys), ScenarioCatalog.allocations)
        XCTAssertEqual(
            Set(Budgets.launchByScenario.keys),
            Set(PerfScenarioDefinitions.all.compactMap { definition in
                definition.launchBudgetMilliseconds == nil ? nil : definition.id
            })
        )
        XCTAssertEqual(Set(ManifestBuilder.defaultTemplates.swiftui), ScenarioCatalog.swiftUI)
        XCTAssertEqual(Set(ManifestBuilder.defaultTemplates.allocations), ScenarioCatalog.allocations)
    }

    func testSharedScenarioSourceKeepsNamingContractsConsistent() {
        for definition in PerfScenarioDefinitions.all {
            XCTAssertEqual(definition.signpostName, definition.id)
            XCTAssertEqual(
                definition.disablesVisualOptions,
                definition.id.hasSuffix("-visual-options-disabled")
            )
        }
    }

    func testSharedScenarioCatalogMatchesUIHitchRateInventory() throws {
        let actual = try uiPerfTestMethodNames(
            matching: #"\bfunc\s+(test[A-Za-z0-9]+HitchRate)\s*\("#,
            relativePaths: [
                "Tests/HarnessMonitorUITests/HarnessMonitorPerfTests+HitchRates.swift",
                "Tests/HarnessMonitorUITests/HarnessMonitorPerfTests+VisualOptions.swift",
            ]
        )
        let expected = Set(
            PerfScenarioDefinitions.all.map { testMethodName(for: $0.id, suffix: "HitchRate") }
        ).union([
            testMethodName(for: "settings-database-scroll", suffix: "HitchRate"),
        ])

        XCTAssertEqual(actual, expected)
        XCTAssertFalse(ScenarioCatalog.all.contains("settings-database-scroll"))
    }

    func testVisualOptionsDisabledScenariosKeepScenarioStateCoverage() throws {
        let actual = try uiPerfTestMethodNames(
            matching: #"\bfunc\s+(test[A-Za-z0-9]+ScenarioState)\s*\("#,
            relativePaths: [
                "Tests/HarnessMonitorUITests/HarnessMonitorPerfTests+VisualOptions.swift",
            ]
        )
        let expected = Set(
            PerfScenarioDefinitions.all
                .filter(\.disablesVisualOptions)
                .map { testMethodName(for: $0.id, suffix: "ScenarioState") }
        )

        XCTAssertEqual(actual, expected)
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

    private func uiPerfTestMethodNames(
        matching pattern: String,
        relativePaths: [String]
    ) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: pattern)
        return try relativePaths.reduce(into: Set<String>()) { collected, relativePath in
            let sourceURL = appRootURL.appendingPathComponent(relativePath)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range) {
                guard match.numberOfRanges == 2,
                    let methodRange = Range(match.range(at: 1), in: source)
                else {
                    continue
                }
                collected.insert(String(source[methodRange]))
            }
        }
    }

    private func testMethodName(
        for scenarioID: String,
        suffix: String
    ) -> String {
        let stem = scenarioID
            .split(separator: "-")
            .map { component in
                component.prefix(1).uppercased() + component.dropFirst()
            }
            .joined()
        return "test\(stem)\(suffix)"
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
