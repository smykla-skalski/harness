import XCTest

final class AuditContractDocsTests: XCTestCase {
    private func readRepoFile(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRootURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testMiseDefinesAuditValidationTasks() throws {
        let mise = try readRepoFile(".mise.toml")
        XCTAssertTrue(mise.contains(#"[tasks."monitor:test:scripts"]"#))
        XCTAssertTrue(mise.contains(#"[tasks."monitor:tools:test:perf"]"#))
        XCTAssertTrue(mise.contains(#"[tasks."monitor:audit"]"#))
        XCTAssertTrue(mise.contains(#"[tasks."monitor:audit:from-ref"]"#))
    }

    func testPerfSkillUsesAnimationIntervalContract() throws {
        let skill = try readRepoFile("local-skills/claude/swiftui-performance-macos/SKILL.md")
        XCTAssertTrue(skill.contains("beginAnimationInterval"))
        XCTAssertTrue(skill.contains("monitor:test:scripts"))
        XCTAssertTrue(skill.contains("monitor:tools:test:perf"))
    }

    func testPerfSkillScenarioChecklistUsesSharedCatalog() throws {
        let skill = try readRepoFile("local-skills/claude/swiftui-performance-macos/SKILL.md")
        XCTAssertTrue(skill.contains("Resources/HarnessMonitorPerfScenarios.json"))
        XCTAssertTrue(skill.contains("ScenarioContractParityTests"))
        XCTAssertFalse(skill.contains("7. `ScenarioCatalog.swift`"))
        XCTAssertFalse(skill.contains("8. `Budgets.swift`"))
        XCTAssertFalse(skill.contains("9. `ManifestBuilder.defaultTemplates`"))
    }

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
