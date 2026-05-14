import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session window route content metrics")
struct SessionWindowRouteContentMetricsTests {
  @Test("Metrics scale overview and row chrome")
  func metricsScaleOverviewAndRowChrome() {
    let regular = SessionWindowRouteContentMetrics(fontScale: 1.0)
    let large = SessionWindowRouteContentMetrics(fontScale: 1.8)

    #expect(large.contentPadding > regular.contentPadding)
    #expect(large.overviewSpacing > regular.overviewSpacing)
    #expect(large.gridHorizontalSpacing > regular.gridHorizontalSpacing)
    #expect(large.gridVerticalSpacing > regular.gridVerticalSpacing)
    #expect(large.rowTextSpacing > regular.rowTextSpacing)
  }

  @Test("Metrics clamp extreme font scales")
  func metricsClampExtremeFontScales() {
    #expect(
      SessionWindowRouteContentMetrics(fontScale: 0.1)
        == SessionWindowRouteContentMetrics(fontScale: 0.85)
    )
    #expect(
      SessionWindowRouteContentMetrics(fontScale: 9.0)
        == SessionWindowRouteContentMetrics(fontScale: 1.8)
    )
  }

  @Test("Task detail pane metrics scale and clamp with the session font scale")
  func taskDetailPaneMetricsScaleAndClampWithSessionFontScale() {
    let regular = SessionTaskDetailPaneMetrics(fontScale: 1.0)
    let large = SessionTaskDetailPaneMetrics(fontScale: 1.8)

    #expect(large.contentPadding > regular.contentPadding)
    #expect(
      SessionTaskDetailPaneMetrics(fontScale: 0.1)
        == SessionTaskDetailPaneMetrics(fontScale: 0.85)
    )
    #expect(
      SessionTaskDetailPaneMetrics(fontScale: 9.0)
        == SessionTaskDetailPaneMetrics(fontScale: 1.8)
    )
  }

  @Test("Task board overview metrics scale and preserve button hit targets")
  func taskBoardOverviewMetricsScaleAndPreserveButtonHitTargets() {
    let regular = TaskBoardOverviewMetrics(fontScale: 1.0)
    let large = TaskBoardOverviewMetrics(fontScale: 1.8)

    #expect(regular.controlMinHeight >= 28)
    #expect(regular.iconControlMinWidth >= 30)
    #expect(large.managementPanelMinHeight > regular.managementPanelMinHeight)
    #expect(
      TaskBoardOverviewMetrics(fontScale: 0.1)
        == TaskBoardOverviewMetrics(fontScale: 0.85)
    )
    #expect(
      TaskBoardOverviewMetrics(fontScale: 9.0)
        == TaskBoardOverviewMetrics(fontScale: 1.8)
    )
  }

  @Test("Task selection renders a real detail pane")
  func taskSelectionRendersARealDetailPane() throws {
    let detailFocusSource = try sourceFile(named: "SessionWindowView+DetailFocus.swift")

    #expect(detailFocusSource.contains("SessionTaskDetailPane("))
    #expect(!detailFocusSource.contains("Task detail lands in a later chunk."))
  }

  @Test("Overview route embeds the task board")
  func overviewRouteEmbedsTaskBoard() throws {
    let routeContentSource = try sourceFile(named: "SessionWindowRouteContent.swift")

    #expect(routeContentSource.contains("TaskBoardOverviewView("))
    #expect(routeContentSource.contains("onOpenItem: openTaskActions"))
  }

  @Test("Dashboard starts from the global task board")
  func dashboardStartsFromGlobalTaskBoard() throws {
    let boardSource = try sourceFile(named: "SessionsBoardView.swift")

    #expect(boardSource.contains("TaskBoardOverviewView("))
    #expect(boardSource.contains("dashboardUI.taskBoardItems"))
    #expect(boardSource.contains("dashboardUI.taskBoardEvaluationSummary"))
    #expect(boardSource.contains("onEvaluateTaskBoard: evaluateTaskBoard"))
    #expect(boardSource.contains("onMoveTaskBoardItem: moveTaskBoardItem"))
    #expect(boardSource.contains("decisions: store.supervisorOpenDecisions"))
  }

  @Test("Overview and dashboard expose task board orchestrator controls")
  func overviewAndDashboardExposeTaskBoardOrchestratorControls() throws {
    let routeContentSource = try sourceFile(named: "SessionWindowRouteContent.swift")
    let boardSource = try sourceFile(named: "SessionsBoardView.swift")

    for source in [routeContentSource, boardSource] {
      #expect(source.contains("onStartTaskBoardOrchestrator: startTaskBoardOrchestrator"))
      #expect(source.contains("onStopTaskBoardOrchestrator: stopTaskBoardOrchestrator"))
      #expect(source.contains("onRunTaskBoardOrchestratorOnce: runTaskBoardOrchestratorOnce"))
      #expect(source.contains("onMoveTaskBoardItem: moveTaskBoardItem"))
    }

    #expect(routeContentSource.contains("store.contentUI.dashboard.taskBoardOrchestratorStatus"))
    #expect(boardSource.contains("dashboardUI.taskBoardOrchestratorStatus"))
  }

  @Test("Board-only task board items have a management surface")
  func boardOnlyTaskBoardItemsHaveManagementSurface() throws {
    let overviewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")
    let managementPanelSource = try taskBoardSourceFile(named: "TaskBoardItemManagementPanel.swift")
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")

    #expect(overviewSource.contains("TaskBoardItemManagementPanel("))
    #expect(managementPanelSource.contains("harness.task-board.manage-item"))
    #expect(overviewSource.contains("TaskBoardOrchestratorRunOnceRequest(itemId: item.id"))
    #expect(!overviewSource.contains("if !item.hasLinkedSessionTask"))
    #expect(managementPanelSource.contains("Session Task"))
    #expect(managementPanelSource.contains("Board Only"))
    #expect(!laneSource.contains(".disabled(!isOpenable)"))
    #expect(!laneSource.contains("private var isOpenable"))
  }

  @Test("Task board lanes expose card drag and lane drop")
  func taskBoardLanesExposeCardDragAndLaneDrop() throws {
    let overviewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let needsYouSource = try taskBoardSourceFile(named: "TaskBoardNeedsYouLaneViews.swift")

    #expect(overviewSource.contains("lane.taskBoardDropStatus"))
    #expect(laneSource.contains("TaskBoardItemDragPayload"))
    #expect(laneSource.contains(".draggable(dragPayload)"))
    #expect(laneSource.contains(".dropDestination(for: TaskBoardItemDragPayload.self"))
    #expect(needsYouSource.contains(".dropDestination(for: TaskBoardItemDragPayload.self"))
  }

  private func sourceFile(named relativePath: String) throws -> String {
    try previewableSourceFile(domain: "Sessions", named: relativePath)
  }

  private func taskBoardSourceFile(named relativePath: String) throws -> String {
    try previewableSourceFile(domain: "TaskBoard", named: relativePath)
  }

  private func previewableSourceFile(domain: String, named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent("Views")
      .appendingPathComponent(domain)
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
