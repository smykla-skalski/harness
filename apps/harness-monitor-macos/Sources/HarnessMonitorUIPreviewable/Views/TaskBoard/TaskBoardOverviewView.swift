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
  let onEvaluateTaskBoard: (() -> Void)?
  let onEvaluateTaskBoardItem: ((TaskBoardItem) -> Void)?
  let onRefreshTaskBoard: (() -> Void)?
  let onStartTaskBoardOrchestrator: (() -> Void)?
  let onStopTaskBoardOrchestrator: (() -> Void)?
  let onRunTaskBoardOrchestratorOnce: ((TaskBoardOrchestratorRunOnceRequest) -> Void)?
  @Environment(\.fontScale)
  private var fontScale
  @State private var selectedTaskBoardItemID: String?

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
    onEvaluateTaskBoard: (() -> Void)? = nil,
    onEvaluateTaskBoardItem: ((TaskBoardItem) -> Void)? = nil,
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
    self.onEvaluateTaskBoard = onEvaluateTaskBoard
    self.onEvaluateTaskBoardItem = onEvaluateTaskBoardItem
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
        if let selectedTaskBoardItem {
          TaskBoardItemManagementPanel(
            item: selectedTaskBoardItem,
            metrics: metrics,
            isActionInFlight: isActionInFlight,
            onRunOnce: runOrchestratorOnceForItem,
            onEvaluate: selectedTaskBoardItemEvaluateAction,
            onRefresh: onRefreshTaskBoard,
            onClose: clearSelectedTaskBoardItem
          )
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
    if shouldOpenLinkedTask(item) {
      selectedTaskBoardItemID = nil
      onOpenTaskBoardItem(item)
    } else if selectedTaskBoardItemID == item.id {
      selectedTaskBoardItemID = nil
    } else {
      selectedTaskBoardItemID = item.id
    }
  }

  private func shouldOpenLinkedTask(_ item: TaskBoardItem) -> Bool {
    guard item.hasLinkedSessionTask else {
      return false
    }
    guard !snapshot.items.isEmpty else {
      return true
    }
    return snapshot.items.contains { inboxItem in
      inboxItem.session.sessionId == item.sessionId
        && inboxItem.task.taskId == item.workItemId
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
    onMoveTaskBoardItem(itemID, lane.taskBoardDropStatus)
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
  }

  private func runOrchestratorOnce() {
    onRunTaskBoardOrchestratorOnce?(TaskBoardOrchestratorRunOnceRequest())
  }

  private func runOrchestratorOnceForItem(_ item: TaskBoardItem) {
    onRunTaskBoardOrchestratorOnce?(
      TaskBoardOrchestratorRunOnceRequest(itemId: item.id, status: item.status)
    )
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
