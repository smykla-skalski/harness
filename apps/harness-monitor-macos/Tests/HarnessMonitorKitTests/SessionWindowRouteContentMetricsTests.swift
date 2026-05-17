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
    #expect(large.laneFixedHeight > regular.laneFixedHeight)
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
    let overviewTaskBoardSource = try sourceFile(named: "SessionWindowOverview+TaskBoard.swift")
    let hostSource = try taskBoardSourceFile(named: "TaskBoardOverviewHost.swift")
    let columnsSource = try sourceFile(named: "SessionWindowView+Columns.swift")

    #expect(routeContentSource.contains("TaskBoardOverviewHost("))
    #expect(routeContentSource.contains("scope: .session(sessionID: snapshot.summary.sessionId)"))
    #expect(routeContentSource.contains("decisions: decisions"))
    #expect(
      routeContentSource.contains(
        "orchestratorStatus: store.contentUI.dashboard.taskBoardOrchestratorStatus"
      )
    )
    #expect(
      routeContentSource.contains(
        "evaluationSummary: store.contentUI.dashboard.taskBoardEvaluationSummary"
      )
    )
    #expect(hostSource.contains("onOpenTaskBoardItem: openTaskBoardItem"))
    #expect(hostSource.contains("onOpenDecision: openDecision"))
    #expect(hostSource.contains("store.supervisorSelectedDecisionID = decision.id"))
    #expect(hostSource.contains("store.requestSessionRoute("))
    #expect(overviewTaskBoardSource.contains("store.contentUI.dashboard.taskBoardItems"))
    #expect(columnsSource.contains("decisions: matchingDecisions"))
  }

  @Test("Dashboard starts from the global task board")
  func dashboardStartsFromGlobalTaskBoard() throws {
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardWindowSupport.swift"
    )

    #expect(dashboardSource.contains("TaskBoardOverviewHost("))
    #expect(dashboardSource.contains("scope: .dashboard"))
    #expect(dashboardSource.contains("snapshot: taskBoardInboxSnapshot"))
    #expect(dashboardSource.contains("store.loadCachedTaskBoardInboxSnapshot("))
    #expect(dashboardSource.contains("sessions: visibleTaskBoardSessions"))
    #expect(dashboardSource.contains("dashboardUI.taskBoardItems"))
    #expect(dashboardSource.contains("dashboardUI.taskBoardEvaluationSummary"))
    #expect(dashboardSource.contains("dashboardUI.taskBoardOrchestratorStatus"))
    #expect(dashboardSource.contains("decisions: store.supervisorOpenDecisions"))
    #expect(dashboardSource.contains("horizontalPadding: 0"))
    #expect(!dashboardSource.contains(".ignoresSafeArea(.container, edges: .top)"))
    #expect(dashboardSource.contains(".padding(.horizontal, detailRowHorizontalPadding)"))
  }

  @Test("Overview and dashboard expose task board orchestrator controls")
  func overviewAndDashboardExposeTaskBoardOrchestratorControls() throws {
    let routeContentSource = try sourceFile(named: "SessionWindowRouteContent.swift")
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardWindowSupport.swift"
    )
    let hostSource = try taskBoardSourceFile(named: "TaskBoardOverviewHost.swift")

    for source in [hostSource] {
      #expect(source.contains("onStartTaskBoardOrchestrator: startTaskBoardOrchestrator"))
      #expect(source.contains("onStopTaskBoardOrchestrator: stopTaskBoardOrchestrator"))
      #expect(source.contains("onRunTaskBoardOrchestratorOnce: runTaskBoardOrchestratorOnce"))
      #expect(source.contains("onMoveTaskBoardItem: moveTaskBoardItem"))
      #expect(source.contains("onEvaluateTaskBoardItem: evaluateTaskBoardItem"))
      #expect(source.contains("onBeginTaskBoardPlan: beginTaskBoardPlan"))
      #expect(source.contains("onSubmitTaskBoardPlan: submitTaskBoardPlan"))
      #expect(source.contains("onApproveTaskBoardPlan: approveTaskBoardPlan"))
    }

    #expect(routeContentSource.contains("TaskBoardOverviewHost("))
    #expect(routeContentSource.contains("store.contentUI.dashboard.taskBoardOrchestratorStatus"))
    #expect(dashboardSource.contains("TaskBoardOverviewHost("))
    #expect(dashboardSource.contains("dashboardUI.taskBoardOrchestratorStatus"))
  }

  @Test("Task board controls stay explicit after chrome cleanup")
  func taskBoardControlsStayExplicitAfterChromeCleanup() throws {
    let overviewSource = try taskBoardOverviewSource()
    let orchestratorSource = try taskBoardSourceFile(
      named: "TaskBoardOrchestratorSummaryView.swift"
    )
    let managementPanelSource = try taskBoardSourceFile(named: "TaskBoardItemManagementPanel.swift")

    #expect(overviewSource.contains("Label(\"Refresh\", systemImage: \"arrow.clockwise\")"))
    #expect(
      overviewSource.contains(
        ".harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)"
      )
    )
    #expect(orchestratorSource.contains(".harnessActionButtonStyle(variant: .prominent"))
    #expect(managementPanelSource.contains("Label(\"Refresh\", systemImage: \"arrow.clockwise\")"))
    #expect(overviewSource.contains("boardAccessoryRow"))
    #expect(overviewSource.contains("headerActionButtons"))
  }

  @Test("Task board operations panel prefers a three-card row")
  func taskBoardOperationsPanelPrefersThreeCardRow() throws {
    let operationsSource = try taskBoardSourceFile(named: "TaskBoardOperationsPanel.swift")
    let layoutSource = try taskBoardSourceFile(named: "TaskBoardOperationsPanelLayout.swift")
    let componentsSource = try taskBoardSourceFile(
      named: "TaskBoardOperationsPanel+Components.swift"
    )
    let inventorySource = try taskBoardSourceFile(
      named: "TaskBoardOperationsPanelInventoryContent.swift"
    )
    let textFieldSource = try taskBoardSourceFile(named: "TaskBoardOperationsTextField.swift")
    let supportSource = try taskBoardSourceFile(named: "TaskBoardOverviewSupport.swift")

    #expect(operationsSource.contains("TaskBoardOperationsPanelLayout("))
    #expect(layoutSource.contains("TaskBoardOperationsResponsiveLayout("))
    #expect(layoutSource.contains("private struct TaskBoardOperationsResponsiveLayout: Layout"))
    #expect(layoutSource.contains("maxColumnWidth: metrics.operationsCardMaxWidth"))
    #expect(layoutSource.contains("minColumnWidth * 3 + spacing * 2"))
    #expect(layoutSource.contains("private var horizontalMaxWidth"))
    #expect(layoutSource.contains("if width >= horizontalMinWidth"))
    #expect(layoutSource.contains("placeHorizontal(in: bounds, subviews: subviews)"))
    #expect(layoutSource.contains("placeVertical(in: bounds, subviews: subviews)"))
    #expect(layoutSource.contains("bounds.midX - (layoutWidth / 2)"))
    #expect(
      layoutSource.contains("return max(minColumnWidth, (width - totalSpacing) / CGFloat(count))")
    )
    #expect(componentsSource.contains("TaskBoardOperationsFormSection("))
    #expect(componentsSource.contains("TaskBoardOperationsFormRow("))
    #expect(componentsSource.contains("contentMaxWidth: nil"))
    #expect(componentsSource.contains("minWidth: 0"))
    #expect(componentsSource.contains("Picker(\"\", selection: selection)"))
    #expect(componentsSource.contains(".labelsHidden()"))
    #expect(componentsSource.contains(".toggleStyle(.switch)"))
    #expect(componentsSource.contains("TaskBoardOperationsTextField("))
    #expect(textFieldSource.contains("TextField(\"\", text: $text, prompt: Text(prompt))"))
    #expect(textFieldSource.contains(".frame(minWidth: 0, maxWidth: .infinity"))
    #expect(inventorySource.contains("HarnessMonitorWrapLayout("))
    #expect(inventorySource.contains("rowAlignment: .trailing"))
    #expect(componentsSource.contains("alignment: .trailing"))
    #expect(componentsSource.contains("alignment: .leading"))
    #expect(!componentsSource.contains("Form {"))
    #expect(!componentsSource.contains("LabeledContent("))
    #expect(!componentsSource.contains(".padding(.horizontal, -HarnessMonitorTheme.spacingXS)"))
    #expect(!layoutSource.contains(".padding(.horizontal, -HarnessMonitorTheme.spacingSM)"))
    #expect(supportSource.contains("let operationsCardMinWidth: CGFloat"))
    #expect(supportSource.contains("let operationsCardMaxWidth: CGFloat"))
  }

  @Test("Board-only task board items have a management surface")
  func boardOnlyTaskBoardItemsHaveManagementSurface() throws {
    let overviewSource = try taskBoardOverviewSource()
    let managementPanelSource = try taskBoardSourceFile(named: "TaskBoardItemManagementPanel.swift")
    let managementSupportSource = try taskBoardSourceFile(
      named: "TaskBoardItemManagementSupport.swift"
    )
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")

    #expect(overviewSource.contains("TaskBoardItemManagementPanel("))
    #expect(managementPanelSource.contains("harness.task-board.manage-item"))
    #expect(overviewSource.contains("TaskBoardOverviewItemBehavior.runOnceRequest(for: item)"))
    #expect(overviewSource.contains("onEvaluateTaskBoardItem(item)"))
    #expect(!overviewSource.contains("if !item.hasLinkedSessionTask"))
    #expect(overviewSource.contains("TaskBoardOverviewItemBehavior.selectionAction("))
    #expect(overviewSource.contains("inboxItems: cachedPresentation.inboxItems(in: lane)"))
    #expect(managementPanelSource.contains("Session Task"))
    #expect(managementPanelSource.contains("Board Only"))
    #expect(managementPanelSource.contains("TaskBoardManagementFacts("))
    #expect(managementPanelSource.contains("TaskBoardExternalLinks("))
    #expect(managementSupportSource.contains("Link(destination: destination.url)"))
    #expect(managementPanelSource.contains("Evaluate Item"))
    #expect(managementPanelSource.contains("TaskBoardPlanLifecycleActionButtons("))
    #expect(managementSupportSource.contains("Label(\"Begin Plan\""))
    #expect(managementSupportSource.contains("Label(\"Submit Plan\""))
    #expect(managementSupportSource.contains("Label(\"Approve Plan\""))
    #expect(!laneSource.contains(".disabled(!isOpenable)"))
    #expect(!laneSource.contains("private var isOpenable"))
  }

  @Test("Task board lanes expose card drag and lane drop")
  func taskBoardLanesExposeCardDragAndLaneDrop() throws {
    let overviewSource = try taskBoardOverviewSource()
    let laneSource = try taskBoardSourceFile(named: "TaskBoardLaneViews.swift")
    let laneSupportSource = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")
    let unifiedSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")

    #expect(overviewSource.contains("lane.taskBoardDropStatus"))
    #expect(laneSource.contains("TaskBoardItemDragPayload"))
    #expect(laneSource.contains("TaskBoardInboxItemDragPayload"))
    #expect(laneSource.contains("let status: TaskBoardStatus"))
    #expect(unifiedSource.contains("TaskBoardLaneDropPolicy.moveFirstPayload("))
    #expect(unifiedSource.contains("TaskBoardInboxDropPolicy.moveFirstPayload("))
    #expect(laneSupportSource.contains("TaskBoardInboxDropPolicy"))
    #expect(laneSupportSource.contains("sourceLane != destination"))
    #expect(laneSource.contains(".draggable(dragPayload)"))
    #expect(laneSource.contains(".onDrag {"))
    #expect(unifiedSource.contains(".dropDestination(for: TaskBoardItemDragPayload.self"))
    #expect(unifiedSource.contains(".dropDestination(for: TaskBoardInboxItemDragPayload.self"))
    #expect(unifiedSource.contains(".onDrop("))
  }

  @Test("Task board lanes keep board column chrome")
  func taskBoardLanesKeepBoardColumnChrome() throws {
    let unifiedSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneSupportSource = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")
    let overviewSource = try taskBoardSourceFile(named: "TaskBoardOverviewView.swift")

    #expect(unifiedSource.contains(".taskBoardLaneColumnChrome("))
    #expect(laneSupportSource.contains("private struct TaskBoardLaneColumnChrome"))
    #expect(laneSupportSource.contains("private var laneFill: AnyShapeStyle"))
    #expect(
      laneSupportSource.contains(
        "RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)"
      )
    )
    #expect(
      laneSupportSource.contains(".strokeBorder(laneStrokeColor, lineWidth: laneStrokeWidth)"))
    #expect(laneSupportSource.contains("private var laneStrokeColor: Color"))
    #expect(laneSupportSource.contains("private var laneStrokeWidth: CGFloat"))
    #expect(!overviewSource.contains("Board-owned work awaiting progression."))
    #expect(!overviewSource.contains("Open work pulled from active sessions."))
  }

  @Test("Task board lanes render every card instead of hiding overflow")
  func taskBoardLanesRenderEveryCardInsteadOfHidingOverflow() throws {
    let unifiedSource = try taskBoardSourceFile(named: "TaskBoardLaneUnifiedColumn.swift")
    let laneSupportSource = try taskBoardSourceFile(named: "TaskBoardLaneSupport.swift")

    #expect(unifiedSource.contains("ForEach(apiItems)"))
    #expect(unifiedSource.contains("ForEach(inboxItems)"))
    #expect(unifiedSource.contains("ForEach(decisions, id: \\.id)"))
    #expect(!unifiedSource.contains(".prefix(5)"))
    #expect(!unifiedSource.contains(".prefix(4)"))
    #expect(!unifiedSource.contains("TaskBoardLaneOverflowRow("))
    #expect(!laneSupportSource.contains("TaskBoardLaneOverflowRow"))
  }

  private func sourceFile(named relativePath: String) throws -> String {
    try previewableSourceFile(domain: "Sessions", named: relativePath)
  }

  private func taskBoardSourceFile(named relativePath: String) throws -> String {
    try previewableSourceFile(domain: "TaskBoard", named: relativePath)
  }

  private func taskBoardOverviewSource() throws -> String {
    try [
      taskBoardSourceFile(named: "TaskBoardOverviewView.swift"),
      taskBoardSourceFile(named: "TaskBoardOverviewView+Support.swift"),
    ].joined(separator: "\n")
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
