import HarnessMonitorKit
import SwiftUI

public struct TaskBoardOverviewView: View {
  let snapshot: TaskBoardInboxSnapshot
  let taskBoardItems: [TaskBoardItem]
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
      header
      if snapshot.isEmpty && taskBoardItems.isEmpty && decisions.isEmpty
        && orchestratorStatus == nil
      {
        emptyState
      } else {
        if let orchestratorStatus {
          TaskBoardOrchestratorSummaryView(
            status: orchestratorStatus,
            latestEvaluation: evaluationSummary,
            isActionInFlight: isActionInFlight,
            onStart: onStartTaskBoardOrchestrator,
            onStop: onStopTaskBoardOrchestrator,
            onRunOnce: runOrchestratorOnce
          )
        } else if let evaluationSummary {
          evaluationSummaryRow(evaluationSummary)
        }
        if !taskBoardItems.isEmpty || !decisions.isEmpty {
          taskBoard
        }
        if isCreatingTaskBoardItem || selectedTaskBoardItem != nil {
          TaskBoardItemManagementPanel(
            item: selectedTaskBoardItem,
            metrics: metrics,
            isActionInFlight: isActionInFlight,
            onCreate: onCreateTaskBoardItem,
            onUpdate: onUpdateTaskBoardItem,
            onDelete: onDeleteTaskBoardItem,
            onRunOnce: runOrchestratorOnceForItem,
            onEvaluate: selectedTaskBoardItemEvaluateAction,
            onBeginPlan: onBeginTaskBoardPlan,
            onSubmitPlan: onSubmitTaskBoardPlan,
            onApprovePlan: onApproveTaskBoardPlan,
            onRefresh: onRefreshTaskBoard,
            onClose: clearSelectedTaskBoardItem
          )
          .id(selectedTaskBoardItem?.id ?? "new")
        }
        if !snapshot.isEmpty {
          sessionTaskBoard
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.overview")
  }
}

extension TaskBoardOverviewView {
  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        headerTitle
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        headerActionsAndSummary
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        headerTitle
        headerActionsAndSummary
      }
    }
    .accessibilityAddTraits(.isHeader)
  }

  private var headerTitle: some View {
    Label("Task Board", systemImage: "rectangle.3.group")
      .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
  }

  private var headerActionsAndSummary: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      headerActions
      if hasAggregateSummary {
        aggregateSummaryRow
      }
    }
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

  private var taskBoard: some View {
    TaskBoardSection(title: "Board Queue") {
      taskBoardColumns
    }
  }

  private var taskBoardColumns: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(taskBoardSections) { section in
          if section.lane == .needsYou {
            TaskBoardNeedsYouLaneColumn(
              section: section,
              decisions: decisions,
              onOpenItem: openTaskBoardItem,
              onMoveItem: moveTaskBoardItem,
              onOpenDecision: onOpenDecision
            )
          } else {
            TaskBoardItemLaneColumn(
              section: section,
              onOpenItem: openTaskBoardItem,
              onMoveItem: moveTaskBoardItem
            )
          }
        }
      }
      .padding(.vertical, HarnessMonitorTheme.spacingXS)
    }
    .scrollClipDisabled()
  }

  private var sessionTaskBoard: some View {
    TaskBoardSection(title: "Session Tasks") {
      inboxBoard
    }
  }

  private var inboxBoard: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(snapshot.sections) { section in
          TaskBoardInboxLaneColumn(
            section: section,
            onOpenItem: onOpenItem,
            onMoveItem: moveInboxItem
          )
        }
      }
      .padding(.vertical, 2)
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
    switch TaskBoardOverviewItemBehavior.selectionAction(
      for: item,
      selectedTaskBoardItemID: selectedTaskBoardItemID,
      inboxItems: snapshot.items
    ) {
    case .openLinkedTask:
      isCreatingTaskBoardItem = false
      selectedTaskBoardItemID = nil
      onOpenTaskBoardItem(item)
    case .selectBoardItem:
      isCreatingTaskBoardItem = false
      selectedTaskBoardItemID = item.id
    case .clearBoardSelection:
      isCreatingTaskBoardItem = false
      selectedTaskBoardItemID = nil
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
