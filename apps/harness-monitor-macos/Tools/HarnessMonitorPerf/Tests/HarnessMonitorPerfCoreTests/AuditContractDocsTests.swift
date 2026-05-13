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

    func testReadmeDocumentsAuditOutputTrustSurface() throws {
        let readme = try readRepoFile("apps/harness-monitor-macos/README.md")
        XCTAssertTrue(readme.contains("`manifest.json`"))
        XCTAssertTrue(readme.contains("`build_provenance`"))
        XCTAssertTrue(readme.contains("`launched_process_path`"))
        XCTAssertTrue(readme.contains("`daemon_data_home_probe`"))
        XCTAssertTrue(readme.contains("`debug-retention.json`"))
    }

    func testMonitorReferenceDocumentsFieldTelemetryPlaybook() throws {
        let guide = try readRepoFile("docs/agent-guides/monitor-reference.md")
        XCTAssertTrue(guide.contains("MetricKit"))
        XCTAssertTrue(guide.contains("Organizer"))
        XCTAssertTrue(guide.contains("App Store Connect Performance API"))
        XCTAssertTrue(guide.contains("launch_app_init_to_ready_ms"))
        XCTAssertTrue(guide.contains("potential_hangs"))
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
