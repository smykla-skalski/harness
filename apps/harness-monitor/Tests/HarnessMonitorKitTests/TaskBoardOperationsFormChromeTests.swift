import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board operations form chrome")
struct TaskBoardOperationsFormChromeTests {
  @Test("Operations form metrics keep a roomier settings-like rhythm")
  func operationsFormMetricsKeepARoomierSettingsLikeRhythm() {
    #expect(TaskBoardOperationsFormMetrics.sectionPadding == HarnessMonitorTheme.spacingLG)
    #expect(TaskBoardOperationsFormMetrics.sectionCornerRadius == HarnessMonitorTheme.cornerRadiusSM)
    #expect(TaskBoardOperationsFormMetrics.rowMinHeight >= 40)
    #expect(TaskBoardOperationsFormMetrics.rowVerticalPadding == HarnessMonitorTheme.spacingSM)
    #expect(TaskBoardOperationsFormMetrics.footerTopPadding == HarnessMonitorTheme.spacingSM)
  }

  @Test("Operations sections keep stronger outer hierarchy than the inner rows")
  func operationsSectionsKeepStrongerOuterHierarchyThanTheInnerRows() throws {
    let componentsSource = try taskBoardSourceFile(named: "TaskBoardOperationsPanel+Components.swift")
    let sectionsSource = try taskBoardSourceFile(named: "TaskBoardOperationsPanel+Sections.swift")

    #expect(componentsSource.contains("static let sectionSurface = HarnessMonitorTheme.ink.opacity(0.04)"))
    #expect(componentsSource.contains(".foregroundStyle(.secondary)"))
    #expect(sectionsSource.contains(".foregroundStyle(.primary)"))
    #expect(sectionsSource.contains(".foregroundStyle(.secondary)"))
    #expect(sectionsSource.contains(".padding(.top, TaskBoardOperationsFormMetrics.footerTopPadding)"))
    #expect(sectionsSource.contains(".padding(.bottom, TaskBoardOperationsFormMetrics.sectionPadding)"))
    #expect(!sectionsSource.contains(".foregroundStyle(HarnessMonitorTheme.secondaryInk)"))
  }

  private func taskBoardSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent("Views/TaskBoard")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
