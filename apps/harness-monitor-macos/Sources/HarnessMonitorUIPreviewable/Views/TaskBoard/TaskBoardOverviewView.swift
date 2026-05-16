import HarnessMonitorKit
import SwiftUI

public struct TaskBoardOverviewView: View {
  let snapshot: TaskBoardInboxSnapshot
  let taskBoardItems: [TaskBoardItem]
  let store: HarnessMonitorStore?
  let orchestratorStatus: TaskBoardOrchestratorStatus?
  let evaluationSummary: TaskBoardEvaluationSummary?
  let decisions: [Decision]
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
  private var fontScale
  @State private var selectedTaskBoardItemID: String?
  @State private var isCreatingTaskBoardItem = false

  private var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }

  public init(
    snapshot: TaskBoardInboxSnapshot,
    taskBoardItems: [TaskBoardItem] = [],
    store: HarnessMonitorStore? = nil,
    orchestratorStatus: TaskBoardOrchestratorStatus? = nil,
    evaluationSummary: TaskBoardEvaluationSummary? = nil,
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
    onRunTaskBoardOrchestratorOnce: ((TaskBoardOrchestratorRunOnceRequest) -> Void)? = nil
  ) {
    self.snapshot = snapshot
    self.taskBoardItems = Self.sortedTaskBoardItems(taskBoardItems)
    self.store = store
    self.orchestratorStatus = orchestratorStatus
    self.evaluationSummary = evaluationSummary
    self.decisions = Self.sortedDecisions(decisions)
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
        if let store {
          taskBoardDetailRow {
            TaskBoardOperationsPanel(store: store, taskBoardItems: taskBoardItems)
          }
        }
      }
      taskBoardDetailRow { boardSection }
      if hasRouteContent || store != nil,
        isCreatingTaskBoardItem || selectedTaskBoardItem != nil
      {
        taskBoardDetailRow {
          TaskBoardItemManagementPanel(
            item: selectedTaskBoardItem,
            metrics: metrics,
            isActionInFlight: isActionInFlight,
            store: store,
            onCreate: onCreateTaskBoardItem,
            onUpdate: onUpdateTaskBoardItem,
            onDelete: selectionClearingDeleteAction,
            onRunOnce: runOrchestratorOnceForItem,
            onEvaluate: selectedTaskBoardItemEvaluateAction,
            onBeginPlan: onBeginTaskBoardPlan,
            onSubmitPlan: onSubmitTaskBoardPlan,
            onApprovePlan: onApproveTaskBoardPlan,
            onRefresh: onRefreshTaskBoard,
            onClose: clearSelectedTaskBoardItem
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.overview")
  }
}

extension TaskBoardOverviewView {
  private var detailRowHorizontalPadding: CGFloat {
    24
  }

  func taskBoardDetailRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(.horizontal, detailRowHorizontalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var hasRouteContent: Bool {
    !snapshot.isEmpty || !taskBoardItems.isEmpty || !decisions.isEmpty || orchestratorStatus != nil
      || evaluationSummary != nil
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
          headerTitle
          Spacer(minLength: HarnessMonitorTheme.spacingMD)
          headerActions
        }
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          headerTitle
          headerActions
        }
      }
      if hasAggregateSummary {
        aggregateSummaryRow
      }
    }
  }

  private var headerTitle: some View {
    Label("Task Board", systemImage: "rectangle.3.group")
      .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
      .accessibilityAddTraits(.isHeader)
  }

  private var headerActions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        headerActionButtons
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        headerActionButtons
      }
    }
  }

  @ViewBuilder private var headerActionButtons: some View {
    if onCreateTaskBoardItem != nil {
      Button {
        startTaskBoardItemCreation()
      } label: {
        Label("New Item", systemImage: "plus.circle")
          .scaledFont(.caption.weight(.semibold))
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
          .scaledFont(.caption.weight(.semibold))
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
          .scaledFont(.caption.weight(.semibold))
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Refresh task board")
      .accessibilityIdentifier("harness.task-board.refresh")
    }
  }

  private var aggregateSummaryRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        aggregateSummaryContent
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        aggregateSummaryContent
      }
    }
  }

  private func evaluationSummaryRow(_ summary: TaskBoardEvaluationSummary) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        evaluationSummaryContent(summary)
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        evaluationSummaryContent(summary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("harness.task-board.evaluation-summary")
  }

  private var hasBoardContent: Bool {
    !taskBoardItems.isEmpty || !decisions.isEmpty || !snapshot.isEmpty
  }

  private var boardSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      header
      if hasBoardContent {
        taskBoardColumns
      } else {
        emptyState
      }
    }
  }

  private var taskBoardColumns: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      HStack(alignment: .top, spacing: metrics.columnSpacing) {
        ForEach(TaskBoardInboxLane.allCases) { lane in
          TaskBoardLaneUnifiedColumn(
            lane: lane,
            apiItems: taskBoardItems.filter { TaskBoardInboxLane(status: $0.status) == lane },
            inboxItems: snapshot.items.filter { $0.lane == lane },
            decisions: lane == .needsYou ? decisions : [],
            onOpenAPIItem: openTaskBoardItem,
            onOpenInboxItem: onOpenItem,
            onOpenDecision: onOpenDecision,
            onMoveAPIItem: moveTaskBoardItem,
            onMoveInboxItem: moveInboxItem
          )
        }
      }
      .padding(.vertical, metrics.boardVerticalPadding)
    }
    .scrollClipDisabled()
  }

  private var emptyState: some View {
    ContentUnavailableView("No Open Tasks", systemImage: "tray")
      .scaledFont(.body)
      .frame(maxWidth: .infinity, minHeight: 180)
      .background(
        .background.opacity(0.45), in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
  }

  private var selectedTaskBoardItem: TaskBoardItem? {
    guard let selectedTaskBoardItemID else { return nil }
    return taskBoardItems.first { $0.id == selectedTaskBoardItemID }
  }

  private func openTaskBoardItem(_ item: TaskBoardItem) {
    switch TaskBoardOverviewItemBehavior.selectionAction(for: item) {
    case .openLinkedTask:
      isCreatingTaskBoardItem = false
      selectedTaskBoardItemID = nil
      onOpenTaskBoardItem(item)
    case .selectBoardItem:
      isCreatingTaskBoardItem = false
      selectedTaskBoardItemID = item.id
    }
  }

  private func moveTaskBoardItem(_ itemID: String, to lane: TaskBoardInboxLane) -> Bool {
    guard let onMoveTaskBoardItem else {
      return false
    }
    guard
      let item = taskBoardItems.first(where: { $0.id == itemID }),
      let currentLane = TaskBoardInboxLane(status: item.status),
      currentLane != lane
    else {
      return false
    }
    onMoveTaskBoardItem(itemID, lane.taskBoardDropStatus(for: item))
    return true
  }

  private func moveInboxItem(
    _ payload: TaskBoardInboxItemDragPayload,
    to lane: TaskBoardInboxLane
  ) -> Bool {
    guard
      let onMoveInboxItem,
      let status = lane.taskDropStatus,
      let item = snapshot.items.first(where: {
        $0.session.sessionId == payload.sessionID && $0.task.taskId == payload.taskID
      }),
      item.lane != lane
    else {
      return false
    }
    onMoveInboxItem(item, status)
    return true
  }

  private func clearSelectedTaskBoardItem() {
    selectedTaskBoardItemID = nil
    isCreatingTaskBoardItem = false
  }

  private var selectionClearingDeleteAction: ((TaskBoardItem) -> Void)? {
    guard let delete = onDeleteTaskBoardItem else { return nil }
    return { item in
      if selectedTaskBoardItemID == item.id {
        selectedTaskBoardItemID = nil
      }
      delete(item)
    }
  }

  private func startTaskBoardItemCreation() {
    selectedTaskBoardItemID = nil
    isCreatingTaskBoardItem = true
  }

  private func runOrchestratorOnce() {
    onRunTaskBoardOrchestratorOnce?(TaskBoardOrchestratorRunOnceRequest())
  }

  private func runOrchestratorOnceForItem(_ item: TaskBoardItem) {
    onRunTaskBoardOrchestratorOnce?(TaskBoardOverviewItemBehavior.runOnceRequest(for: item))
  }

  private var selectedTaskBoardItemEvaluateAction: ((TaskBoardItem) -> Void)? {
    guard onEvaluateTaskBoardItem != nil || onEvaluateTaskBoard != nil else {
      return nil
    }
    return evaluateSelectedTaskBoardItem
  }

  private func evaluateSelectedTaskBoardItem(_ item: TaskBoardItem) {
    if let onEvaluateTaskBoardItem {
      onEvaluateTaskBoardItem(item)
    } else {
      onEvaluateTaskBoard?()
    }
    selectedTaskBoardItemID = item.id
  }

}
