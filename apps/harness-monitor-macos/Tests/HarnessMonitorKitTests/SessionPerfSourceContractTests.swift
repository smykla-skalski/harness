import Foundation
import Testing

@Suite("Session perf source contracts")
struct SessionPerfSourceContractTests {
  @Test("Perf scenarios keep synthetic UI-test controls out of traces")
  func perfScenariosKeepSyntheticControlsOutOfTraces() throws {
    let source = try appSourceFile(
      at: "HarnessMonitorAppSceneSupport+WorkspaceUITestForceTick.swift"
    )

    #expect(source.contains("HarnessMonitorUITestEnvironment.generalMarkersEnabled"))
    #expect(!source.contains("HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {"))
  }

  @Test("Perf scripts begin only after their prerequisites are ready")
  func perfScriptsBeginOnlyAfterPrerequisitesAreReady() throws {
    let source = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowView+PerfScenarios.swift"
    )

    #expect(source.contains("guard trigger.hasSearchCorpus else { return }"))
    #expect(source.contains("guard !trigger.sidebarToggleTargets.isEmpty else { return }"))
    #expect(source.contains("recordScriptBegin(baseScenario: baseScenario, sessionID: sessionID)"))
    let prematureBegin =
      "let baseScenario = HarnessMonitorUITestEnvironment.basePerfScenario(for: scenario)\n"
      + "    HarnessMonitorPerfTrace.recordScenarioEvent("
    #expect(!source.contains(prematureBegin))
  }

  @Test("Perf sidebar and route scripts avoid restoration writeback churn")
  func perfScriptsAvoidRestorationWritebackChurn() throws {
    let persistenceSource = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowView+SelectionPersistence.swift"
    )
    let layoutSource = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowStandardLayout.swift"
    )

    #expect(
      persistenceSource.contains("guard !HarnessMonitorUITestEnvironment.isPerfScenarioActive")
    )
    #expect(layoutSource.contains("@State private var perfColumnVisibilityStorage"))
    #expect(layoutSource.contains("if HarnessMonitorUITestEnvironment.isPerfScenarioActive"))
    #expect(layoutSource.contains("perfColumnVisibilityStorage = storedVisibility"))
  }

  private func appSourceFile(at relativePath: String) throws -> String {
    try sourceFile(root: "Sources/HarnessMonitor/App", relativePath: relativePath)
  }

  private func previewableSourceFile(at relativePath: String) throws -> String {
    try sourceFile(root: "Sources/HarnessMonitorUIPreviewable", relativePath: relativePath)
  }

  private func sourceFile(root: String, relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos")
      .appendingPathComponent(root)
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
