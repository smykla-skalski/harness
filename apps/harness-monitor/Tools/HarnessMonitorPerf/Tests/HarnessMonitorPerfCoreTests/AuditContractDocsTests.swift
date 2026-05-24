import XCTest
@testable import HarnessMonitorPerfCore

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
        XCTAssertTrue(mise.contains(#"[tasks."monitor:tools:generate:schemas"]"#))
        XCTAssertTrue(mise.contains(#"[tasks."monitor:tools:field-telemetry"]"#))
        XCTAssertTrue(mise.contains(#"[tasks."monitor:audit"]"#))
        XCTAssertTrue(mise.contains(#"[tasks."monitor:audit:from-ref"]"#))
        let bisectTask = try readRepoFile("mise-tasks/monitor/audit/bisect")
        XCTAssertTrue(bisectTask.contains(#"depends=["monitor:tools:build:perf"]"#))
        XCTAssertTrue(bisectTask.contains("run-instruments-audit-bisect.sh"))
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
        let readme = try readRepoFile("apps/harness-monitor/README.md")
        XCTAssertTrue(readme.contains("`manifest.json`"))
        XCTAssertTrue(readme.contains("`build_provenance`"))
        XCTAssertTrue(readme.contains("`launched_process_path`"))
        XCTAssertTrue(readme.contains("`daemon_data_home_probe`"))
        XCTAssertTrue(readme.contains("`app_trace_relpath`"))
        XCTAssertTrue(readme.contains("`app_trace`"))
        XCTAssertTrue(readme.contains("`findings`"))
        XCTAssertTrue(readme.contains("app-trace pair/diff"))
        XCTAssertTrue(readme.contains("monitor:tools:generate:schemas"))
        XCTAssertTrue(readme.contains("monitor:tools:field-telemetry"))
        XCTAssertTrue(readme.contains("`debug-retention.json`"))
    }

    func testMonitorReferenceDocumentsFieldTelemetryPlaybook() throws {
        let guide = try readRepoFile("docs/agent-guides/monitor-reference.md")
        XCTAssertTrue(guide.contains("MetricKit"))
        XCTAssertTrue(guide.contains("Organizer"))
        XCTAssertTrue(guide.contains("App Store Connect Performance API"))
        XCTAssertTrue(guide.contains("launch_app_init_to_ready_ms"))
        XCTAssertTrue(guide.contains("potential_hangs"))
        XCTAssertTrue(guide.contains("monitor:tools:generate:schemas"))
        XCTAssertTrue(guide.contains("monitor:tools:field-telemetry"))
    }

    func testAuditOutputSchemasExistAndStayMachineReadable() throws {
        let manifest = try readRepoFile(
            "apps/harness-monitor/Tools/HarnessMonitorPerf/Schemas/manifest.schema.json"
        )
        let summary = try readRepoFile(
            "apps/harness-monitor/Tools/HarnessMonitorPerf/Schemas/summary.schema.json"
        )
        let comparison = try readRepoFile(
            "apps/harness-monitor/Tools/HarnessMonitorPerf/Schemas/comparison.schema.json"
        )

        XCTAssertNoThrow(try jsonObject(from: manifest))
        XCTAssertNoThrow(try jsonObject(from: summary))
        XCTAssertNoThrow(try jsonObject(from: comparison))

        let generatedDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("perf-schema-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: generatedDir) }
        try SchemaSnapshots.write(to: generatedDir)

        let generatedManifest = try String(
            contentsOf: generatedDir.appendingPathComponent("manifest.schema.json"),
            encoding: .utf8
        )
        let generatedSummary = try String(
            contentsOf: generatedDir.appendingPathComponent("summary.schema.json"),
            encoding: .utf8
        )
        let generatedComparison = try String(
            contentsOf: generatedDir.appendingPathComponent("comparison.schema.json"),
            encoding: .utf8
        )
        let regenerationHint =
            "Run `mise run monitor:tools:generate:schemas` and commit the updated snapshots."
        XCTAssertEqual(manifest, generatedManifest, regenerationHint)
        XCTAssertEqual(summary, generatedSummary, regenerationHint)
        XCTAssertEqual(comparison, generatedComparison, regenerationHint)

        XCTAssertTrue(manifest.contains("\"build_provenance\""))
        XCTAssertTrue(manifest.contains("\"staged_host_bundle_id\""))
        XCTAssertTrue(manifest.contains("\"launched_process_path\""))
        XCTAssertTrue(manifest.contains("\"daemon_data_home_probe\""))
        XCTAssertTrue(manifest.contains("\"app_trace_relpath\""))

        XCTAssertTrue(summary.contains("\"metrics\""))
        XCTAssertTrue(summary.contains("\"launch_metrics\""))
        XCTAssertTrue(summary.contains("\"metric_tiers\""))
        XCTAssertTrue(summary.contains("\"app_trace\""))
        XCTAssertTrue(summary.contains("\"findings\""))

        XCTAssertTrue(comparison.contains("\"missing_from_current\""))
        XCTAssertTrue(comparison.contains("\"shared_metrics\""))
        XCTAssertTrue(comparison.contains("\"top_frames\""))
        XCTAssertTrue(comparison.contains("\"app_trace\""))
        XCTAssertTrue(comparison.contains("\"new_findings\""))
        XCTAssertTrue(comparison.contains("\"resolved_findings\""))
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

    private func jsonObject(from source: String) throws -> Any {
        let data = try XCTUnwrap(source.data(using: .utf8))
        return try JSONSerialization.jsonObject(with: data)
    }
}
