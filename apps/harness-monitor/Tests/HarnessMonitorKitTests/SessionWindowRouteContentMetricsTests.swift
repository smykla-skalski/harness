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
    #expect(large.overviewCardMinWidth > regular.overviewCardMinWidth)
    #expect(large.overviewCardMinHeight > regular.overviewCardMinHeight)
    #expect(large.overviewCardTextSpacing > regular.overviewCardTextSpacing)
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
    #expect(large.cardMarkerSize > regular.cardMarkerSize)
    #expect(large.cardPadding > regular.cardPadding)
    #expect(large.pillHorizontalPadding > regular.pillHorizontalPadding)
    #expect(large.headerIconWidth > regular.headerIconWidth)
    #expect(regular.laneCollapsedTitleHeight >= 160)
    #expect(large.laneCollapsedTitleHeight > regular.laneCollapsedTitleHeight)
    #expect(
      TaskBoardLaneMetrics(fontScale: 0.1)
        == TaskBoardLaneMetrics(fontScale: 0.85)
    )
    #expect(
      TaskBoardLaneMetrics(fontScale: 9.0)
        == TaskBoardLaneMetrics(fontScale: 1.8)
    )
  }

  @Test("Task board card drop plans move only cross-lane payloads")
  func taskBoardCardDropPlansMoveOnlyCrossLanePayloads() {
    let item = TaskBoardCardDragItem.api(itemID: "item-1", status: .todo)
    let payload = TaskBoardCardDragPayload(item: item)

    #expect(TaskBoardCardDropPlan.resolve([], to: .todo) == nil)
    #expect(TaskBoardCardDropPlan.resolve([payload], to: .todo) == nil)
    #expect(TaskBoardCardDropPlan.resolve([payload], to: .inProgress)?.items == [item])
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
    #expect(
      hostSource.contains("contentHorizontalPadding: scope.taskBoardContentHorizontalPadding"))
    #expect(hostSource.contains("case .session:\n      0"))
    #expect(overviewTaskBoardSource.contains("store.contentUI.dashboard.taskBoardItems"))
    #expect(columnsSource.contains("decisions: matchingDecisions"))
  }

  @Test("Overview route presents summary cards instead of a duplicate title header")
  func overviewRoutePresentsSummaryCardsInsteadOfDuplicateTitleHeader() throws {
    let routeContentSource = try sourceFile(named: "SessionWindowRouteContent.swift")

    #expect(
      routeContentSource.contains(
        "SessionOverviewInfoStrip(facts: overviewFacts, metrics: metrics)"))
    #expect(routeContentSource.contains("ViewThatFits(in: .horizontal)"))
    #expect(routeContentSource.contains("SessionOverviewFactCard"))
    #expect(!routeContentSource.contains("Text(snapshot.summary.displayTitle)"))
  }

  @Test("Dashboard starts from the global task board")
  func dashboardStartsFromGlobalTaskBoard() throws {
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
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
    #expect(dashboardSource.contains("HarnessMonitorColumnScrollView("))
  }

  @Test("Dashboard owns global task board controls while sessions retain item actions")
  func dashboardOwnsGlobalTaskBoardControls() throws {
    let routeContentSource = try sourceFile(named: "SessionWindowRouteContent.swift")
    let dashboardSource = try previewableSourceFile(
      domain: "Dashboard",
      named: "DashboardRouteContent.swift"
    )
    let hostSource = try taskBoardSourceFile(named: "TaskBoardOverviewHost.swift")

    for source in [hostSource] {
      #expect(
        source.contains(
          "onStartTaskBoardOrchestrator: scope.isDashboard ? startTaskBoardOrchestrator : nil"
        )
      )
      #expect(
        source.contains(
          "onStopTaskBoardOrchestrator: scope.isDashboard ? stopTaskBoardOrchestrator : nil"
        )
      )
      #expect(source.contains("onRunTaskBoardOrchestratorOnce: runTaskBoardOrchestratorOnce"))
      #expect(source.contains("onMoveTaskBoardItems: moveTaskBoardItems"))
      #expect(source.contains("onMoveInboxItems: moveInboxItems"))
      #expect(source.contains("onDeleteTaskBoardTargets: deleteTaskBoardTargets"))
      #expect(source.contains("HarnessMonitorAsyncWorkQueue.shared.submit("))
      #expect(source.contains("await store.updateTaskBoardItemStatuses(updates)"))
      #expect(source.contains("await store.updateTaskBoardInboxStatuses(updates)"))
      #expect(source.contains("onEvaluateTaskBoardItem: evaluateTaskBoardItem"))
      #expect(source.contains("onBeginTaskBoardPlan: beginTaskBoardPlan"))
      #expect(source.contains("onSubmitTaskBoardPlan: submitTaskBoardPlan"))
      #expect(source.contains("onApproveTaskBoardPlan: approveTaskBoardPlan"))
    }

    #expect(routeContentSource.contains("TaskBoardOverviewHost("))
    #expect(routeContentSource.contains("store.contentUI.dashboard.taskBoardOrchestratorStatus"))
    #expect(routeContentSource.contains("showsOperationsPanel: false"))
    #expect(hostSource.contains("onRefreshTaskBoard: scope.isDashboard ? refreshTaskBoard : nil"))
    #expect(dashboardSource.contains("TaskBoardOverviewHost("))
    #expect(dashboardSource.contains("dashboardUI.taskBoardOrchestratorStatus"))
  }

  @Test("Task board controls stay explicit after chrome cleanup")
  func taskBoardControlsStayExplicitAfterChromeCleanup() throws {
    let overviewSource = try taskBoardOverviewSource()
    let orchestratorSource = try taskBoardSourceFile(
      named: "TaskBoardOrchestratorSummaryView.swift"
    )
    let managementActionsSource = try taskBoardSourceFile(
      named: "TaskBoardItemLiveActionButtons.swift"
    )

    #expect(overviewSource.contains("Label(\"Sync Live\", systemImage: \"arrow.clockwise\")"))
    #expect(
      overviewSource.contains(
        ".harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)"
      )
    )
    #expect(orchestratorSource.contains(".harnessActionButtonStyle(variant: .prominent"))
    #expect(
      managementActionsSource.contains(
        "Label(\"Sync Live\", systemImage: \"arrow.clockwise\")"
      )
    )
    #expect(managementActionsSource.contains("Run Once Live"))
    #expect(managementActionsSource.contains("Evaluate Item Live"))
    #expect(overviewSource.contains("boardAccessoryRow"))
    #expect(overviewSource.contains("headerActionButtons"))
  }

  @Test("Task board operations panel prefers a three-card row")
  func taskBoardOperationsPanelPrefersThreeCardRow() throws {
    let operationsSource = try taskBoardSourceFile(named: "TaskBoardOperationsPanel.swift")
    let layoutSource = try taskBoardSourceFile(named: "TaskBoardOperationsPanelLayout.swift")
    let componentsSource = try [
      "TaskBoardOperationsPanel+Components.swift",
      "TaskBoardOperationsPanel+Sections.swift",
      "TaskBoardOperationsPanelInventoryContent.swift",
    ]
    .map { try taskBoardSourceFile(named: $0) }
    .joined(separator: "\n")
    let inventorySource = try taskBoardSourceFile(
      named: "TaskBoardOperationsPanelInventoryContent.swift"
    )
    let textFieldSource = try previewableSourceFile(
      domain: "Shared",
      named: "HarnessMonitorInlineTextField.swift"
    )
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
    #expect(layoutSource.contains("max(availableWidth, horizontalMinWidth)"))
    #expect(
      !layoutSource.contains("min(max(availableWidth, horizontalMinWidth), horizontalMaxWidth)"))
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
    #expect(componentsSource.contains("HarnessMonitorInlineTextField("))
    #expect(componentsSource.contains("hasVisibleLabel: true"))
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
      taskBoardSourceFile(named: "TaskBoardOverviewView+Chrome.swift"),
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
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent("Views")
      .appendingPathComponent(domain)
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
