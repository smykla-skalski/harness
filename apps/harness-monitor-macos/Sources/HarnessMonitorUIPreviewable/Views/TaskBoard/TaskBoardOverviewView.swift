import HarnessMonitorKit
import SwiftUI

public struct TaskBoardOverviewView: View {
  private let snapshot: TaskBoardInboxSnapshot
  private let taskBoardItems: [TaskBoardItem]
  private let orchestratorStatus: TaskBoardOrchestratorStatus?
  private let evaluationSummary: TaskBoardEvaluationSummary?
  private let decisions: [Decision]
  private let isActionInFlight: Bool
  private let onOpenItem: (TaskBoardInboxItem) -> Void
  private let onOpenTaskBoardItem: (TaskBoardItem) -> Void
  private let onOpenDecision: (Decision) -> Void
  private let onEvaluateTaskBoard: (() -> Void)?
  private let onRefreshTaskBoard: (() -> Void)?
  private let onStartTaskBoardOrchestrator: (() -> Void)?
  private let onStopTaskBoardOrchestrator: (() -> Void)?
  private let onRunTaskBoardOrchestratorOnce: ((TaskBoardOrchestratorRunOnceRequest) -> Void)?
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
    onOpenDecision: @escaping (Decision) -> Void = { _ in },
    onEvaluateTaskBoard: (() -> Void)? = nil,
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
    self.onOpenDecision = onOpenDecision
    self.onEvaluateTaskBoard = onEvaluateTaskBoard
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
            onEvaluate: evaluateSelectedTaskBoardItem,
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

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
        headerTitle
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        headerActionsAndCounts
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        headerTitle
        headerActionsAndCounts
      }
    }
    .accessibilityAddTraits(.isHeader)
  }

  private var headerTitle: some View {
    Label("Task Board", systemImage: "rectangle.3.group")
      .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
  }

  private var headerActionsAndCounts: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      if let onEvaluateTaskBoard {
        Button {
          onEvaluateTaskBoard()
        } label: {
          Label("Evaluate", systemImage: "checkmark.seal")
        }
        .frame(minHeight: metrics.controlMinHeight)
        .disabled(isActionInFlight)
        .help("Evaluate board state")
        .accessibilityIdentifier("harness.task-board.evaluate")
      }

      if let onRefreshTaskBoard {
        Button {
          onRefreshTaskBoard()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .frame(minWidth: metrics.iconControlMinWidth, minHeight: metrics.controlMinHeight)
        .disabled(isActionInFlight)
        .help("Refresh task board")
        .accessibilityIdentifier("harness.task-board.refresh")
      }

      countPill(
        "\(taskBoardNeedsYouCount + snapshot.needsYouItemCount + decisions.count)",
        label: "Needs You"
      )
      countPill("\(taskBoardItems.count + snapshot.items.count + decisions.count)", label: "Open")
      countPill("\(taskBoardReviewCount + snapshot.reviewItemCount)", label: "Review")
      countPill("\(taskBoardBlockedCount + snapshot.blockedItemCount)", label: "Blocked")
    }
  }

  private func evaluationSummaryRow(_ summary: TaskBoardEvaluationSummary) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      countPill("\(summary.evaluated)/\(summary.total)", label: "Eval")
      if summary.updated != 0 {
        countPill("\(summary.updated)", label: "Updated")
      }
      if summary.failed + summary.blocked != 0 {
        countPill("\(summary.failed + summary.blocked)", label: "Blocked")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("harness.task-board.evaluation-summary")
  }

  private var taskBoard: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Board Items")
        .scaledFont(.subheadline.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      ScrollView(.horizontal, showsIndicators: true) {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
          ForEach(taskBoardSections) { section in
            if section.lane == .needsYou {
              TaskBoardNeedsYouLaneColumn(
                section: section,
                decisions: decisions,
                onOpenItem: openTaskBoardItem,
                onOpenDecision: onOpenDecision
              )
            } else {
              TaskBoardItemLaneColumn(
                section: section,
                onOpenItem: openTaskBoardItem
              )
            }
          }
        }
        .padding(.vertical, 2)
      }
      .scrollClipDisabled()
    }
  }

  private var sessionTaskBoard: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if !taskBoardItems.isEmpty {
        Text("Session Tasks")
          .scaledFont(.subheadline.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      inboxBoard
    }
  }

  private var inboxBoard: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(snapshot.sections) { section in
          TaskBoardInboxLaneColumn(
            section: section,
            onOpenItem: onOpenItem
          )
        }
      }
      .padding(.vertical, 2)
    }
    .scrollClipDisabled()
  }

  private var emptyState: some View {
    ContentUnavailableView("No Open Tasks", systemImage: "tray")
      .frame(maxWidth: .infinity, minHeight: 180)
      .background(
        .background.opacity(0.45), in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
  }

  private func countPill(_ value: String, label: String) -> some View {
    HStack(spacing: 4) {
      Text(value)
        .scaledFont(.caption.weight(.bold))
      Text(label)
        .scaledFont(.caption)
    }
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .harnessPillPadding()
    .harnessControlPill(tint: HarnessMonitorTheme.secondaryInk)
  }

  private var selectedTaskBoardItem: TaskBoardItem? {
    guard let selectedTaskBoardItemID else { return nil }
    return taskBoardItems.first { $0.id == selectedTaskBoardItemID }
  }

  private func openTaskBoardItem(_ item: TaskBoardItem) {
    if !item.hasLinkedSessionTask {
      selectedTaskBoardItemID = item.id
    } else if selectedTaskBoardItemID == item.id {
      selectedTaskBoardItemID = nil
    }
    onOpenTaskBoardItem(item)
  }

  private func clearSelectedTaskBoardItem() {
    selectedTaskBoardItemID = nil
  }

  private func runOrchestratorOnce() {
    onRunTaskBoardOrchestratorOnce?(TaskBoardOrchestratorRunOnceRequest())
  }

  private func runOrchestratorOnceForItem(_ item: TaskBoardItem) {
    onRunTaskBoardOrchestratorOnce?(
      TaskBoardOrchestratorRunOnceRequest(status: item.status)
    )
  }

  private func evaluateSelectedTaskBoardItem(_ item: TaskBoardItem) {
    onEvaluateTaskBoard?()
    selectedTaskBoardItemID = item.id
  }

  private var taskBoardSections: [TaskBoardItemSection] {
    TaskBoardInboxLane.allCases.map { lane in
      TaskBoardItemSection(
        lane: lane,
        items: taskBoardItems.filter { TaskBoardInboxLane(status: $0.status) == lane }
      )
    }
  }

  private var taskBoardReviewCount: Int {
    taskBoardItems.count { TaskBoardInboxLane(status: $0.status) == .review }
  }

  private var taskBoardNeedsYouCount: Int {
    taskBoardItems.count { TaskBoardInboxLane(status: $0.status) == .needsYou }
  }

  private var taskBoardBlockedCount: Int {
    taskBoardItems.count { TaskBoardInboxLane(status: $0.status) == .blocked }
  }

  private static func sortedTaskBoardItems(_ items: [TaskBoardItem]) -> [TaskBoardItem] {
    items
      .filter { TaskBoardInboxLane(status: $0.status) != nil && $0.deletedAt == nil }
      .sorted { left, right in
        if left.priority != right.priority {
          return priorityRank(left.priority) > priorityRank(right.priority)
        }
        if left.updatedAt != right.updatedAt {
          return left.updatedAt > right.updatedAt
        }
        return left.id < right.id
      }
  }

  private static func priorityRank(_ priority: TaskBoardPriority) -> Int {
    switch priority {
    case .critical:
      3
    case .high:
      2
    case .medium:
      1
    case .low:
      0
    }
  }

  private static func sortedDecisions(_ decisions: [Decision]) -> [Decision] {
    decisions
      .filter { $0.statusRaw == "open" }
      .sorted { left, right in
        if severityRank(left.severityRaw) != severityRank(right.severityRaw) {
          return severityRank(left.severityRaw) > severityRank(right.severityRaw)
        }
        return left.createdAt < right.createdAt
      }
  }

  private static func severityRank(_ severity: String) -> Int {
    switch DecisionSeverity(rawValue: severity) {
    case .critical:
      3
    case .needsUser:
      2
    case .warn:
      1
    case .info, nil:
      0
    }
  }
}

struct TaskBoardItemSection: Identifiable {
  let lane: TaskBoardInboxLane
  let items: [TaskBoardItem]

  var id: TaskBoardInboxLane { lane }
}

struct TaskBoardOverviewMetrics: Equatable {
  let controlMinHeight: CGFloat
  let iconControlMinWidth: CGFloat
  let managementPanelMinHeight: CGFloat
  let managementPanelSpacing: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    controlMinHeight = max(28, 28 * min(scale, 1.35))
    iconControlMinWidth = max(30, 30 * min(scale, 1.35))
    managementPanelMinHeight = max(132, 132 * min(scale, 1.25))
    managementPanelSpacing = max(8, 8 * min(scale, 1.35))
  }
}

extension TaskBoardItem {
  var hasLinkedSessionTask: Bool {
    sessionId != nil && workItemId != nil
  }
}
