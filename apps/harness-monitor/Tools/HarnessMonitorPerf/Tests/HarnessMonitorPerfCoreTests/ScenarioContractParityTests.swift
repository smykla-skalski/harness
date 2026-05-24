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
        // Live-daemon scenarios cannot be measured by the XCUITest hitch harness
        // because the host runner does not bring up a real daemon for them. The
        // audit pipeline records them directly via `monitor:audit` instead.
        let expected = Set(
            PerfScenarioDefinitions.all
                .filter { !$0.usesLiveDaemon }
                .map { testMethodName(for: $0.id, suffix: "HitchRate") }
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

    func testSignpostContractMatchesDriverAndSkill() throws {
        let driverRelativePath = "Sources/HarnessMonitor/App/HarnessMonitorPerfDriver.swift"
        let driverURL = appRootURL.appendingPathComponent(driverRelativePath)
        let driverSource = try String(contentsOf: driverURL, encoding: .utf8)
        let initializerPattern = #"(?:OSSignposter|HarnessMonitorSignpostBridge)"#
            + #"\s*\(\s*subsystem:\s*"([^"]+)"\s*,\s*category:\s*"([^"]+)"\s*\)"#
        let initializerRegex = try NSRegularExpression(pattern: initializerPattern)
        let driverRange = NSRange(driverSource.startIndex..<driverSource.endIndex, in: driverSource)
        let initializerMatches = initializerRegex.matches(in: driverSource, range: driverRange)
        XCTAssertEqual(
            initializerMatches.count, 2,
            """
            Expected exactly two signpost initializers \
            (OSSignposter + HarnessMonitorSignpostBridge) in \(driverRelativePath); \
            found \(initializerMatches.count).
            """
        )
        for match in initializerMatches {
            guard match.numberOfRanges == 3,
                let subsystemRange = Range(match.range(at: 1), in: driverSource),
                let categoryRange = Range(match.range(at: 2), in: driverSource)
            else {
                XCTFail(
                    "Failed to extract subsystem/category from initializer match"
                        + " in \(driverRelativePath)."
                )
                continue
            }
            let subsystem = String(driverSource[subsystemRange])
            let category = String(driverSource[categoryRange])
            XCTAssertEqual(
                subsystem, "io.harnessmonitor",
                """
                Driver subsystem in \(driverRelativePath) drifted to "\(subsystem)"; \
                signpost contract requires "io.harnessmonitor".
                """
            )
            XCTAssertEqual(
                category, "perf",
                """
                Driver category in \(driverRelativePath) drifted to "\(category)"; \
                signpost contract requires "perf".
                """
            )
        }

        let skillRelativePath = "local-skills/claude/swiftui-performance-macos/SKILL.md"
        let skillURL = repoRootURL.appendingPathComponent(skillRelativePath)
        let skillSource = try String(contentsOf: skillURL, encoding: .utf8)
        // Description frontmatter locks the "io.harnessmonitor/perf/<scenario>" wording
        // so callers (and grep) can find the signpost contract from the SKILL.md header.
        XCTAssertTrue(
            skillSource.contains("io.harnessmonitor/perf/<scenario>"),
            """
            \(skillRelativePath) description frontmatter must mention the \
            signpost contract literal "io.harnessmonitor/perf/<scenario>".
            """
        )
        // Body must spell out the quoted subsystem and category exactly once each,
        // matching the driver literals. Anything else drifts silently away from the
        // OSSignposter / XCTOSSignpostMetric pairing rule called out in the doc.
        let subsystemSeparator = "\"io.harnessmonitor\""
        let subsystemQuotedOccurrences =
            skillSource.components(separatedBy: subsystemSeparator).count - 1
        XCTAssertEqual(
            subsystemQuotedOccurrences, 1,
            """
            \(skillRelativePath) must mention `"io.harnessmonitor"` exactly once \
            in the body; found \(subsystemQuotedOccurrences) occurrence(s).
            """
        )
        let categorySeparator = "\"perf\""
        let categoryQuotedOccurrences =
            skillSource.components(separatedBy: categorySeparator).count - 1
        XCTAssertEqual(
            categoryQuotedOccurrences, 1,
            """
            \(skillRelativePath) must mention `"perf"` exactly once in the body; \
            found \(categoryQuotedOccurrences) occurrence(s).
            """
        )
    }

    func testMiseTasksReferencedInSkillAndDocsExist() throws {
        let miseURL = repoRootURL.appendingPathComponent(".mise.toml")
        let miseSource = try String(contentsOf: miseURL, encoding: .utf8)
        let miseTaskRegex = try NSRegularExpression(
            pattern: #"^\[tasks\."(monitor:[^"]+)"\]$"#,
            options: [.anchorsMatchLines]
        )
        let miseRange = NSRange(miseSource.startIndex..<miseSource.endIndex, in: miseSource)
        let declaredTasks: Set<String> = Set(
            miseTaskRegex.matches(in: miseSource, range: miseRange).compactMap { match in
                guard match.numberOfRanges == 2,
                    let taskRange = Range(match.range(at: 1), in: miseSource)
                else { return nil }
                return String(miseSource[taskRange])
            }
        )
        XCTAssertFalse(
            declaredTasks.isEmpty,
            "Expected to discover at least one `monitor:*` task in .mise.toml; the regex may have drifted."
        )

        let documentRelativePaths: [(label: String, url: URL)] = [
            (
                "local-skills/claude/swiftui-performance-macos/SKILL.md",
                repoRootURL.appendingPathComponent(
                    "local-skills/claude/swiftui-performance-macos/SKILL.md"
                )
            ),
            (
                "apps/harness-monitor/AGENTS.md",
                appRootURL.appendingPathComponent("AGENTS.md")
            ),
        ]
        let referenceRegex = try NSRegularExpression(
            pattern: #"mise run (monitor:[A-Za-z0-9:_-]+)"#
        )
        var unknownReferences: [(document: String, task: String)] = []
        for entry in documentRelativePaths {
            // AGENTS.md is optional per spec; SKILL.md is required for the contract to be useful.
            guard let source = try? String(contentsOf: entry.url, encoding: .utf8) else {
                continue
            }
            let documentRange = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in referenceRegex.matches(in: source, range: documentRange) {
                guard match.numberOfRanges == 2,
                    let taskRange = Range(match.range(at: 1), in: source)
                else { continue }
                let referencedTask = String(source[taskRange])
                if !declaredTasks.contains(referencedTask) {
                    unknownReferences.append((document: entry.label, task: referencedTask))
                }
            }
        }
        XCTAssertTrue(
            unknownReferences.isEmpty,
            "Docs reference mise tasks not declared in .mise.toml: "
                + unknownReferences
                    .map { "\($0.document) -> `mise run \($0.task)`" }
                    .joined(separator: ", ")
        )
    }

    func testScenarioIDsReferencedInSkillExist() throws {
        // The conservative kebab-case extractor would catch tokens like `dereference` or
        // `xcodebuild` that look scenario-shaped without being scenarios, so this contract
        // uses a hand-picked allowlist of scenario ids the SKILL.md is expected to mention.
        // When new scenario ids land in the doc, append them here so the contract keeps
        // tracking them.
        let expectedScenarioMentions: [String] = [
            "open-recent-window",
        ]
        let skillRelativePath = "local-skills/claude/swiftui-performance-macos/SKILL.md"
        let skillURL = repoRootURL.appendingPathComponent(skillRelativePath)
        let skillSource = try String(contentsOf: skillURL, encoding: .utf8)
        let validScenarioIDs = Set(ScenarioCatalog.all).union(["settings-database-scroll"])

        for scenarioID in expectedScenarioMentions {
            XCTAssertTrue(
                skillSource.contains(scenarioID),
                """
                \(skillRelativePath) must mention scenario id `\(scenarioID)` \
                to keep the signpost-name example concrete.
                """
            )
            XCTAssertTrue(
                validScenarioIDs.contains(scenarioID),
                """
                Allowlisted scenario id `\(scenarioID)` is not present in \
                ScenarioCatalog.all ∪ {"settings-database-scroll"}; either the \
                catalog drifted or the allowlist is stale.
                """
            )
        }
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

    private var repoRootURL: URL {
        appRootURL.deletingLastPathComponent().deletingLastPathComponent()
    }
}
