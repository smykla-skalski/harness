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

  @Test("Task board lane metrics scale card and lane geometry")
  func taskBoardLaneMetricsScaleCardAndLaneGeometry() {
    let regular = TaskBoardLaneMetrics(fontScale: 1.0)
    let large = TaskBoardLaneMetrics(fontScale: 1.8)

    #expect(large.laneWidth > regular.laneWidth)
    #expect(large.laneMinHeight > regular.laneMinHeight)
    #expect(large.laneBodyMinHeight > regular.laneBodyMinHeight)
    #expect(large.cardMinHeight > regular.cardMinHeight)
    #expect(large.cardPadding > regular.cardPadding)
    #expect(large.pillHorizontalPadding > regular.pillHorizontalPadding)
    #expect(large.headerIconWidth > regular.headerIconWidth)
    #expect(
      TaskBoardLaneMetrics(fontScale: 0.1)
        == TaskBoardLaneMetrics(fontScale: 0.85)
    )
    #expect(
      TaskBoardLaneMetrics(fontScale: 9.0)
        == TaskBoardLaneMetrics(fontScale: 1.8)
    )
  }

  @Test("Task board lane drop policy moves only cross-lane payloads")
  func taskBoardLaneDropPolicyMovesOnlyCrossLanePayloads() {
    var moves: [String] = []
    let readyPayload = TaskBoardItemDragPayload(itemID: "item-1", status: .todo)

    #expect(
      !TaskBoardLaneDropPolicy.moveFirstPayload([], to: .ready) { itemID, lane in
        moves.append("\(itemID):\(lane.rawValue)")
        return true
      }
    )
    #expect(
      !TaskBoardLaneDropPolicy.moveFirstPayload([readyPayload], to: .ready) { itemID, lane in
        moves.append("\(itemID):\(lane.rawValue)")
        return true
      }
    )
    #expect(moves.isEmpty)

    #expect(
      TaskBoardLaneDropPolicy.moveFirstPayload([readyPayload], to: .running) { itemID, lane in
        moves.append("\(itemID):\(lane.rawValue)")
        return true
      }
    )
    #expect(moves == ["item-1:running"])
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
    let columnsSource = try sourceFile(named: "SessionWindowView+Columns.swift")

    #expect(routeContentSource.contains("TaskBoardOverviewView("))
    #expect(routeContentSource.contains("let decisions: [Decision]"))
    #expect(routeContentSource.contains("decisions: decisions"))
    #expect(routeContentSource.contains("onOpenItem: openTaskActions"))
    #expect(routeContentSource.contains("onOpenDecision: openDecision"))
    #expect(routeContentSource.contains("private func openDecision(_ decision: Decision)"))
    #expect(routeContentSource.contains("store.supervisorSelectedDecisionID = decision.id"))
    #expect(routeContentSource.contains("store.requestSessionRoute("))
    #expect(columnsSource.contains("decisions: matchingDecisions"))
  }

  @Test("Dashboard starts from the global task board")
  func dashboardStartsFromGlobalTaskBoard() throws {
    let boardSource = try sourceFile(named: "SessionsBoardView.swift")

    #expect(boardSource.contains("TaskBoardOverviewView("))
    #expect(boardSource.contains("dashboardUI.taskBoardItems"))
    #expect(boardSource.contains("dashboardUI.taskBoardEvaluationSummary"))
    #expect(boardSource.contains("onEvaluateTaskBoard: evaluateTaskBoard"))
    #expect(boardSource.contains("onEvaluateTaskBoardItem: evaluateTaskBoardItem"))
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
      #expect(source.contains("onEvaluateTaskBoardItem: evaluateTaskBoardItem"))
    }

    #expect(routeContentSource.contains("store.contentUI.dashboard.taskBoardOrchestratorStatus"))
    #expect(routeContentSource.contains("store.contentUI.dashboard.taskBoardItems"))
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
    #expect(overviewSource.contains("onEvaluateTaskBoardItem(item)"))
    #expect(!overviewSource.contains("if !item.hasLinkedSessionTask"))
    #expect(overviewSource.contains("shouldOpenLinkedTask("))
    #expect(overviewSource.contains("snapshot.items.contains"))
    #expect(managementPanelSource.contains("Session Task"))
    #expect(managementPanelSource.contains("Board Only"))
    #expect(managementPanelSource.contains("Evaluate Item"))
    #expect(!laneSource.contains(".disabled(!isOpenable)"))
    #expect(!laneSource.contains("private var isOpenable"))
  }

  @Test("Task board lanes expose card drag and lane drop")
  func taskBoardLanesExposeCardDragAndLaneDrop() throws {
    let overviewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let laneSupportSource = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")
    let needsYouSource = try taskBoardSourceFile(named: "TaskBoardNeedsYouLaneViews.swift")

    #expect(overviewSource.contains("lane.taskBoardDropStatus"))
    #expect(laneSource.contains("TaskBoardItemDragPayload"))
    #expect(laneSource.contains("TaskBoardInboxItemDragPayload"))
    #expect(laneSource.contains("let status: TaskBoardStatus"))
    #expect(laneSource.contains("TaskBoardLaneDropPolicy.moveFirstPayload("))
    #expect(laneSupportSource.contains("TaskBoardInboxDropPolicy"))
    #expect(laneSupportSource.contains("payload.sourceLane != destination"))
    #expect(needsYouSource.contains("payload.sourceLane != .needsYou"))
    #expect(laneSource.contains(".draggable(dragPayload)"))
    #expect(laneSource.contains(".dropDestination(for: TaskBoardItemDragPayload.self"))
    #expect(laneSource.contains(".dropDestination(for: TaskBoardInboxItemDragPayload.self"))
    #expect(needsYouSource.contains(".dropDestination(for: TaskBoardItemDragPayload.self"))
  }

  @Test("Task board lanes use flat column chrome")
  func taskBoardLanesUseFlatColumnChrome() throws {
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let laneSupportSource = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")
    let overviewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")

    #expect(laneSource.contains(".taskBoardLaneColumnChrome("))
    #expect(laneSupportSource.contains("private struct TaskBoardLaneColumnChrome"))
    #expect(!laneSource.contains("private var laneAccentColor: Color"))
    #expect(!laneSource.contains("strokeBorder(laneStrokeColor"))
    #expect(!overviewSource.contains("Board-owned work awaiting progression."))
    #expect(!overviewSource.contains("Open work pulled from active sessions."))
  }

  @Test("Task board lanes expose overflow rows for capped columns")
  func taskBoardLanesExposeOverflowRowsForCappedColumns() throws {
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let laneSupportSource = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")
    let needsYouSource = try taskBoardSourceFile(named: "TaskBoardNeedsYouLaneViews.swift")

    #expect(laneSource.contains("TaskBoardLaneOverflowRow(hiddenCount: section.items.count - 5)"))
    #expect(laneSupportSource.contains("Text(\"+\\(hiddenCount) more\")"))
    #expect(needsYouSource.contains("TaskBoardLaneOverflowRow(hiddenCount: hiddenItemCount)"))
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
