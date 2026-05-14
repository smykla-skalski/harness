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
  private let onEvaluateTaskBoard: () -> Void
  private let onRefreshTaskBoard: () -> Void

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
    onEvaluateTaskBoard: @escaping () -> Void = {},
    onRefreshTaskBoard: @escaping () -> Void = {}
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
            latestEvaluation: evaluationSummary
          )
        } else if let evaluationSummary {
          evaluationSummaryRow(evaluationSummary)
        }
        if !taskBoardItems.isEmpty || !decisions.isEmpty {
          taskBoard
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
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
      Label("Task Board", systemImage: "rectangle.3.group")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Button {
          onEvaluateTaskBoard()
        } label: {
          Label("Evaluate", systemImage: "checkmark.seal")
        }
        .disabled(isActionInFlight)
        .help("Evaluate board state")

        Button {
          onRefreshTaskBoard()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(isActionInFlight)
        .help("Refresh task board")

        countPill(
          "\(taskBoardNeedsYouCount + snapshot.needsYouItemCount + decisions.count)",
          label: "Needs You"
        )
        countPill("\(taskBoardItems.count + snapshot.items.count + decisions.count)", label: "Open")
        countPill("\(taskBoardReviewCount + snapshot.reviewItemCount)", label: "Review")
        countPill("\(taskBoardBlockedCount + snapshot.blockedItemCount)", label: "Blocked")
      }
    }
    .accessibilityAddTraits(.isHeader)
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
                onOpenItem: onOpenTaskBoardItem,
                onOpenDecision: onOpenDecision
              )
            } else {
              TaskBoardItemLaneColumn(
                section: section,
                onOpenItem: onOpenTaskBoardItem
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
