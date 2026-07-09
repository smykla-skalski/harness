import HarnessMonitorKit
import SwiftUI

public struct TaskBoardOverviewView: View {
  let snapshot: TaskBoardInboxSnapshot
  let taskBoardItems: [TaskBoardItem]
  let store: HarnessMonitorStore?
  let orchestratorStatus: TaskBoardOrchestratorStatus?
  let evaluationSummary: TaskBoardEvaluationSummary?
  let taskBoardSessionID: String?
  let contentHorizontalPadding: CGFloat
  let fillsAvailableHeight: Bool
  let decisions: [Decision]
  let decisionsByID: [String: Decision]
  let decisionItems: [DecisionPresentationItem]
  let isActionInFlight: Bool
  let onOpenItem: (TaskBoardInboxItem) -> Void
  let onOpenTaskBoardItem: (TaskBoardItem) -> Void
  let onMoveInboxItem: ((TaskBoardInboxItem, TaskStatus) -> Void)?
  let onMoveTaskBoardItem: ((String, TaskBoardStatus) -> Void)?
  let onOpenDecision: (Decision) -> Void
  let onCreateTaskBoardItem: ((TaskBoardCreateItemRequest, TaskBoardStatus) -> Void)?
  let onUpdateTaskBoardItem: ((String, TaskBoardUpdateItemRequest) -> Void)?
  let onDeleteTaskBoardItem: ((TaskBoardItem) -> Void)?
  let onEvaluateTaskBoard: (() -> Void)?
  let onEvaluateTaskBoardItem: ((TaskBoardItem) -> Void)?
  let onBeginTaskBoardPlan: ((TaskBoardItem) -> Void)?
  let onSubmitTaskBoardPlan: ((TaskBoardItem, String) -> Void)?
  let onApproveTaskBoardPlan: ((TaskBoardItem, String, String?) -> Void)?
  let onRefreshTaskBoard: (() -> Void)?
  let onStartTaskBoardOrchestrator: (() -> Void)?
  let onStopTaskBoardOrchestrator: (() -> Void)?
  let onRunTaskBoardOrchestratorOnce: ((TaskBoardOrchestratorRunOnceRequest) -> Void)?
  @Environment(\.fontScale)
  var fontScale
  @State private var selectedTaskBoardItemID: String?
  @State private var isCreatingTaskBoardItem = false
  @State private var evaluationSummaryFitsHorizontally = true
  @State private var presentationWorker = TaskBoardOverviewPresentationWorker()
  @State private var cachedPresentation = TaskBoardOverviewPresentation.empty
  @State private var presentationGeneration: UInt64 = 0
  @AppStorage(TaskBoardLaneCollapsePreferences.storageKey)
  var laneCollapsePreferencesRawValue = TaskBoardLaneCollapsePreferences.emptyRawValue

  var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }
  var titleHeaderFont: Font {
    HarnessMonitorTextSize.scaledFont(
      .system(.title3, design: .rounded, weight: .semibold),
      by: fontScale
    )
  }

  var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }

  var laneMetrics: TaskBoardLaneMetrics {
    TaskBoardLaneMetrics(fontScale: fontScale)
  }

  var laneStripSizing: TaskBoardLaneStripSizing {
    TaskBoardLaneStripSizing(
      minColumnWidth: laneMetrics.laneWidth,
      spacing: metrics.columnSpacing,
      collapsedColumnWidth: laneMetrics.laneCollapsedWidth
    )
  }

  var presentationInput: TaskBoardOverviewPresentationInput {
    TaskBoardOverviewPresentationInput(
      snapshot: snapshot,
      taskBoardItems: taskBoardItems,
      decisionItems: decisionItems,
      scopeSessionID: taskBoardSessionID
    )
  }

  var currentPresentation: TaskBoardOverviewPresentation {
    cachedPresentation
  }

  public init(
    snapshot: TaskBoardInboxSnapshot,
    taskBoardItems: [TaskBoardItem] = [],
    store: HarnessMonitorStore? = nil,
    orchestratorStatus: TaskBoardOrchestratorStatus? = nil,
    evaluationSummary: TaskBoardEvaluationSummary? = nil,
    taskBoardSessionID: String? = nil,
    contentHorizontalPadding: CGFloat = 24,
    fillsAvailableHeight: Bool = false,
    decisions: [Decision] = [],
    isActionInFlight: Bool = false,
    onOpenItem: @escaping (TaskBoardInboxItem) -> Void = { _ in },
    onOpenTaskBoardItem: @escaping (TaskBoardItem) -> Void = { _ in },
    onMoveInboxItem: ((TaskBoardInboxItem, TaskStatus) -> Void)? = nil,
    onMoveTaskBoardItem: ((String, TaskBoardStatus) -> Void)? = nil,
    onOpenDecision: @escaping (Decision) -> Void = { _ in },
    onCreateTaskBoardItem: ((TaskBoardCreateItemRequest, TaskBoardStatus) -> Void)? = nil,
    onUpdateTaskBoardItem: ((String, TaskBoardUpdateItemRequest) -> Void)? = nil,
    onDeleteTaskBoardItem: ((TaskBoardItem) -> Void)? = nil,
    onEvaluateTaskBoard: (() -> Void)? = nil,
    onEvaluateTaskBoardItem: ((TaskBoardItem) -> Void)? = nil,
    onBeginTaskBoardPlan: ((TaskBoardItem) -> Void)? = nil,
    onSubmitTaskBoardPlan: ((TaskBoardItem, String) -> Void)? = nil,
    onApproveTaskBoardPlan: ((TaskBoardItem, String, String?) -> Void)? = nil,
    onRefreshTaskBoard: (() -> Void)? = nil,
    onStartTaskBoardOrchestrator: (() -> Void)? = nil,
    onStopTaskBoardOrchestrator: (() -> Void)? = nil,
    onRunTaskBoardOrchestratorOnce: ((TaskBoardOrchestratorRunOnceRequest) -> Void)? = nil,
    decisionItems: [DecisionPresentationSnapshot]? = nil,
    decisionsByID: [String: Decision]? = nil
  ) {
    self.snapshot = snapshot
    self.taskBoardItems = taskBoardItems
    self.store = store
    self.orchestratorStatus = orchestratorStatus
    self.evaluationSummary = evaluationSummary
    self.taskBoardSessionID = taskBoardSessionID
    self.contentHorizontalPadding = contentHorizontalPadding
    self.fillsAvailableHeight = fillsAvailableHeight
    self.decisions = decisions
    self.decisionsByID =
      decisionsByID ?? Dictionary(uniqueKeysWithValues: decisions.map { ($0.id, $0) })
    self.decisionItems = decisionItems ?? decisions.map(DecisionPresentationItem.init)
    self.isActionInFlight = isActionInFlight
    self.onOpenItem = onOpenItem
    self.onOpenTaskBoardItem = onOpenTaskBoardItem
    self.onMoveInboxItem = onMoveInboxItem
    self.onMoveTaskBoardItem = onMoveTaskBoardItem
    self.onOpenDecision = onOpenDecision
    self.onCreateTaskBoardItem = onCreateTaskBoardItem
    self.onUpdateTaskBoardItem = onUpdateTaskBoardItem
    self.onDeleteTaskBoardItem = onDeleteTaskBoardItem
    self.onEvaluateTaskBoard = onEvaluateTaskBoard
    self.onEvaluateTaskBoardItem = onEvaluateTaskBoardItem
    self.onBeginTaskBoardPlan = onBeginTaskBoardPlan
    self.onSubmitTaskBoardPlan = onSubmitTaskBoardPlan
    self.onApproveTaskBoardPlan = onApproveTaskBoardPlan
    self.onRefreshTaskBoard = onRefreshTaskBoard
    self.onStartTaskBoardOrchestrator = onStartTaskBoardOrchestrator
    self.onStopTaskBoardOrchestrator = onStopTaskBoardOrchestrator
    self.onRunTaskBoardOrchestratorOnce = onRunTaskBoardOrchestratorOnce
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      boardChrome
      taskBoardDetailRow { boardSection }
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsAvailableHeight ? .infinity : nil,
      alignment: fillsAvailableHeight ? .topLeading : .leading
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.overview")
    .sheet(item: taskBoardManagementSheet) { taskBoardManagementSheet in
      taskBoardManagementSheetContent(taskBoardManagementSheet)
    }
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }
  }

  var selectedTaskBoardItemIDValue: String? {
    get { selectedTaskBoardItemID }
    nonmutating set { selectedTaskBoardItemID = newValue }
  }

  var isCreatingTaskBoardItemValue: Bool {
    get { isCreatingTaskBoardItem }
    nonmutating set { isCreatingTaskBoardItem = newValue }
  }
}

extension TaskBoardOverviewView {
  @ViewBuilder var boardChrome: some View {
    if hasRouteContent || store != nil {
      if let orchestratorStatus {
        taskBoardDetailRow {
          TaskBoardOrchestratorSummaryView(
            status: orchestratorStatus,
            latestEvaluation: evaluationSummary,
            isActionInFlight: isActionInFlight,
            onStart: onStartTaskBoardOrchestrator,
            onStop: onStopTaskBoardOrchestrator,
            onRunOnce: runOrchestratorOnce
          )
        }
      } else if let evaluationSummary {
        taskBoardDetailRow { evaluationSummaryRow(evaluationSummary) }
      }
    }
    taskBoardDetailRow { headerTitle }
    if let store {
      taskBoardDetailRow {
        TaskBoardOperationsPanel(store: store, taskBoardItems: cachedPresentation.taskBoardItems)
      }
    }
  }

  var headerTitle: some View {
    Label("Board", systemImage: "rectangle.3.group")
      .font(titleHeaderFont)
      .accessibilityAddTraits(.isHeader)
  }

  var headerActions: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      headerActionButtons
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  var boardAccessoryRow: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
      if hasAggregateSummary {
        aggregateSummaryRow
      }
      if hasAggregateSummary && hasHeaderActions {
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
      }
      if hasHeaderActions {
        headerActions
      }
    }
  }

  var hasHeaderActions: Bool {
    onCreateTaskBoardItem != nil || onEvaluateTaskBoard != nil || onRefreshTaskBoard != nil
  }

  @ViewBuilder var headerActionButtons: some View {
    if onCreateTaskBoardItem != nil {
      Button {
        startTaskBoardItemCreation()
      } label: {
        Label("New Item", systemImage: "plus.circle")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Create board item")
      .accessibilityIdentifier("harness.task-board.new-item")
    }

    if let onEvaluateTaskBoard {
      Button {
        onEvaluateTaskBoard()
      } label: {
        Label("Evaluate", systemImage: "checkmark.seal")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Evaluate board state")
      .accessibilityIdentifier("harness.task-board.evaluate")
    }

    if let onRefreshTaskBoard {
      Button {
        onRefreshTaskBoard()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Refresh task board")
      .accessibilityIdentifier("harness.task-board.refresh")
    }
  }

  var aggregateSummaryRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      aggregateSummaryContent
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  func evaluationSummaryRow(_ summary: TaskBoardEvaluationSummary) -> some View {
    Group {
      if evaluationSummaryFitsHorizontally {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          evaluationSummaryContent(summary)
        }
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          evaluationSummaryContent(summary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      let next = width >= 420
      if evaluationSummaryFitsHorizontally != next {
        evaluationSummaryFitsHorizontally = next
      }
    }
    .accessibilityIdentifier("harness.task-board.evaluation-summary")
  }

  var hasBoardContent: Bool {
    cachedPresentation.hasBoardContent
  }

  var boardSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if hasAggregateSummary || hasHeaderActions {
        boardAccessoryRow
      }
      boardContent
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
    }
    .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
  }

  @ViewBuilder var boardContent: some View {
    if hasBoardContent {
      taskBoardColumns
    } else {
      emptyState
    }
  }

  var taskBoardColumns: some View {
    ViewThatFits(in: .horizontal) {
      TaskBoardLaneStripLayout(sizing: laneStripSizing) {
        taskBoardLaneColumns
      }
      .padding(.vertical, metrics.boardVerticalPadding)

      ScrollView(.horizontal, showsIndicators: true) {
        TaskBoardLaneStripLayout(sizing: laneStripSizing) {
          taskBoardLaneColumns
        }
        .padding(.vertical, metrics.boardVerticalPadding)
      }
      .scrollClipDisabled()
    }
  }

  @ViewBuilder var taskBoardLaneColumns: some View {
    ForEach(TaskBoardInboxLane.allCases) { lane in
      let apiItems = cachedPresentation.apiItems(in: lane)
      let inboxItems = cachedPresentation.inboxItems(in: lane)
      let decisions = decisions(in: lane)
      let contentCount = laneContentCount(
        apiItems: apiItems,
        inboxItems: inboxItems,
        decisions: decisions
      )
      let isCollapsed = isLaneCollapsed(lane, contentCount: contentCount)
      TaskBoardLaneUnifiedColumn(
        lane: lane,
        apiItems: apiItems,
        inboxItems: inboxItems,
        decisions: decisions,
        isCollapsed: isCollapsed,
        onOpenAPIItem: openTaskBoardItem,
        onOpenInboxItem: onOpenItem,
        onOpenDecision: onOpenDecision,
        onToggleCollapse: {
          toggleLaneCollapse(lane, contentCount: contentCount)
        },
        onMoveAPIItem: moveTaskBoardItem,
        onMoveInboxItem: moveInboxItem
      )
      .layoutValue(
        key: TaskBoardLanePreferredWidthKey.self,
        value: isCollapsed ? laneMetrics.laneCollapsedWidth : laneMetrics.laneWidth
      )
      .layoutValue(key: TaskBoardLaneCanExpandKey.self, value: !isCollapsed)
    }
  }

  var emptyState: some View {
    ContentUnavailableView("No Open Tasks", systemImage: "tray")
      .font(bodyFont)
      .frame(maxWidth: .infinity, minHeight: 180)
      .background(
        .background.opacity(0.45), in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
  }

  func decisions(in lane: TaskBoardInboxLane) -> [Decision] {
    cachedPresentation.decisionIDs(in: lane).compactMap { decisionsByID[$0] }
  }

  @MainActor
  func rebuildPresentation(input: TaskBoardOverviewPresentationInput) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let presentation = await presentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
  }
}
