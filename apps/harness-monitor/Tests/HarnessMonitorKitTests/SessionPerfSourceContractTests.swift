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
    let windowSource = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowView.swift"
    )
    let persistenceSource = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowView+SelectionPersistence.swift"
    )
    let layoutSource = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowStandardLayout.swift"
    )

    #expect(
      persistenceSource.contains("guard HarnessMonitorPerfIsolation.allowsSceneRestorationWrites")
    )
    #expect(
      windowSource.contains("guard HarnessMonitorPerfIsolation.allowsSceneRestorationWrites")
    )
    #expect(layoutSource.contains("@State private var perfColumnVisibilityStorage"))
    #expect(layoutSource.contains("if !HarnessMonitorPerfIsolation.allowsSceneRestorationWrites"))
    #expect(layoutSource.contains("perfColumnVisibilityStorage = storedVisibility"))
  }

  @Test("Perf isolation variants gate search and static detail from env flags")
  func perfIsolationVariantsGateSearchAndStaticDetailFromEnvFlags() throws {
    let isolationSource = try previewableSourceFile(
      at: "Support/HarnessMonitorPerfIsolation.swift"
    )
    let windowSource = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowView.swift"
    )
    let searchSource = try previewableSourceFile(
      at: "Views/Search/AppSearchHost.swift"
    )
    let columnsSource = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowView+Columns.swift"
    )

    #expect(isolationSource.contains("HARNESS_MONITOR_PERF_DISABLE_SEARCH_HOST"))
    #expect(isolationSource.contains("HARNESS_MONITOR_PERF_DISABLE_SEARCH_SUGGESTIONS"))
    #expect(isolationSource.contains("HARNESS_MONITOR_PERF_ENABLE_SCENE_WRITES"))
    #expect(isolationSource.contains("HARNESS_MONITOR_PERF_STATIC_DETAIL"))
    #expect(windowSource.contains("!HarnessMonitorPerfIsolation.disablesSearchHost"))
    #expect(searchSource.contains("HarnessMonitorPerfIsolation.disablesSearchSuggestions"))
    #expect(columnsSource.contains("HarnessMonitorPerfIsolation.usesStaticDetail"))
  }

  @Test("Perf scripts emit measured step boundaries")
  func perfScriptsEmitMeasuredStepBoundaries() throws {
    let source = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowView+PerfScenarios.swift"
    )

    #expect(source.contains("HarnessMonitorPerfTrace.beginStep"))
    #expect(source.contains("HarnessMonitorPerfTrace.endStep"))
    #expect(source.contains("runMeasuredStep(\"search.present\")"))
    #expect(source.contains("runMeasuredStep(\"column.detail-only\")"))
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
      .appendingPathComponent("apps/harness-monitor")
      .appendingPathComponent(root)
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
