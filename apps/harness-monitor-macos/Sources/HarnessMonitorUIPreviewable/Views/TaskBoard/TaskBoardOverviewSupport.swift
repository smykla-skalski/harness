import HarnessMonitorKit
import SwiftUI

struct TaskBoardOverviewMetrics: Equatable {
  let controlMinHeight: CGFloat
  let iconControlMinWidth: CGFloat
  let managementPanelMinHeight: CGFloat
  let managementPanelSpacing: CGFloat
  let managementPanelCornerRadius: CGFloat
  let managementPillVerticalPadding: CGFloat
  let summaryPillHorizontalPadding: CGFloat
  let summaryPillVerticalPadding: CGFloat
  let columnSpacing: CGFloat
  let boardVerticalPadding: CGFloat
  let editorBodyMinHeight: CGFloat
  let editorPlanningMinHeight: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    let denseScale = min(scale, 1.3)
    controlMinHeight = max(30, 30 * min(scale, 1.35))
    iconControlMinWidth = max(32, 32 * min(scale, 1.35))
    managementPanelMinHeight = max(132, 132 * min(scale, 1.25))
    managementPanelSpacing = max(8, 8 * min(scale, 1.35))
    managementPanelCornerRadius = HarnessMonitorTheme.cornerRadiusSM * min(scale, 1.2)
    managementPillVerticalPadding = max(3, 3 * min(scale, 1.25))
    summaryPillHorizontalPadding = HarnessMonitorTheme.pillPaddingH * denseScale
    summaryPillVerticalPadding = HarnessMonitorTheme.pillPaddingV * min(scale, 1.2)
    columnSpacing = HarnessMonitorTheme.spacingMD * min(scale, 1.16)
    boardVerticalPadding = HarnessMonitorTheme.spacingXS * min(scale, 1.2)
    editorBodyMinHeight = max(96, 96 * min(scale, 1.2))
    editorPlanningMinHeight = max(72, 72 * min(scale, 1.2))
  }
}

struct TaskBoardSummaryPill: View {
  let value: String
  let label: String
  let systemImage: String?
  let tint: Color
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }

  init(
    value: String,
    label: String,
    systemImage: String? = nil,
    tint: Color = HarnessMonitorTheme.secondaryInk
  ) {
    self.value = value
    self.label = label
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if let systemImage {
        Image(systemName: systemImage)
          .scaledFont(.caption.weight(.semibold))
          .accessibilityHidden(true)
      }
      Text(label)
        .scaledFont(.caption)
      Text(value)
        .scaledFont(.caption.weight(.bold))
        .monospacedDigit()
    }
    .foregroundStyle(tint)
    .padding(.horizontal, metrics.summaryPillHorizontalPadding)
    .padding(.vertical, metrics.summaryPillVerticalPadding)
    .harnessContentPill(tint: tint)
  }
}

struct TaskBoardSection<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.headline.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      content
    }
  }
}

extension TaskBoardItem {
  var hasLinkedSessionTask: Bool {
    sessionId != nil && workItemId != nil
  }

  var isImportedGitHubInboxItem: Bool {
    id.hasPrefix("github-")
      && planning.summary == nil
      && externalRefs.contains(where: { $0.provider == .gitHub })
  }
}

enum TaskBoardOverviewItemSelectionAction: Equatable {
  case openLinkedTask
  case selectBoardItem
}

enum TaskBoardOverviewItemBehavior {
  static func selectionAction(for item: TaskBoardItem) -> TaskBoardOverviewItemSelectionAction {
    if shouldOpenLinkedTask(item) {
      return .openLinkedTask
    }
    return .selectBoardItem
  }

  static func runOnceRequest(for item: TaskBoardItem) -> TaskBoardOrchestratorRunOnceRequest {
    TaskBoardOrchestratorRunOnceRequest(itemId: item.id, status: item.status)
  }

  static func evaluationRequest(for item: TaskBoardItem) -> TaskBoardEvaluateRequest {
    TaskBoardEvaluateRequest(status: item.status, itemId: item.id)
  }

  private static func shouldOpenLinkedTask(_ item: TaskBoardItem) -> Bool {
    item.hasLinkedSessionTask
  }
}

extension TaskBoardInboxLane {
  var taskDropStatus: TaskStatus? {
    switch self {
    case .needsYou:
      nil
    case .ready, .backlog:
      .open
    case .running:
      .inProgress
    case .review:
      .awaitingReview
    case .blocked:
      .blocked
    case .done:
      .done
    }
  }

  var taskBoardDropStatus: TaskBoardStatus {
    switch self {
    case .needsYou:
      .planReview
    case .ready:
      .todo
    case .running:
      .inProgress
    case .review:
      .inReview
    case .blocked:
      .blocked
    case .done:
      .done
    case .backlog:
      .new
    }
  }

  func taskBoardDropStatus(for item: TaskBoardItem) -> TaskBoardStatus {
    switch self {
    case .needsYou:
      return item.status == .needsYou || item.isImportedGitHubInboxItem ? .needsYou : .planReview
    case .backlog:
      return item.status == .planning ? .planning : .new
    case .ready, .running, .review, .blocked, .done:
      return taskBoardDropStatus
    }
  }
}

extension TaskBoardOverviewView {
  var taskBoardReviewCount: Int {
    taskBoardItems.count { TaskBoardInboxLane(status: $0.status) == .review }
  }

  var taskBoardNeedsYouCount: Int {
    taskBoardItems.count { TaskBoardInboxLane(status: $0.status) == .needsYou }
  }

  var taskBoardBlockedCount: Int {
    taskBoardItems.count { TaskBoardInboxLane(status: $0.status) == .blocked }
  }

  var taskBoardDoneCount: Int {
    taskBoardItems.count { TaskBoardInboxLane(status: $0.status) == .done }
  }

  var aggregateNeedsYouCount: Int {
    taskBoardNeedsYouCount + snapshot.needsYouItemCount + decisions.count
  }

  var aggregateOpenCount: Int {
    taskBoardItems.count { $0.status != .done } + snapshot.openItemCount + decisions.count
  }

  var aggregateReviewCount: Int {
    taskBoardReviewCount + snapshot.reviewItemCount
  }

  var aggregateBlockedCount: Int {
    taskBoardBlockedCount + snapshot.blockedItemCount
  }

  var aggregateDoneCount: Int {
    taskBoardDoneCount + snapshot.completedItemCount
  }

  var hasAggregateSummary: Bool {
    aggregateNeedsYouCount != 0 || aggregateOpenCount != 0 || aggregateReviewCount != 0
      || aggregateBlockedCount != 0 || aggregateDoneCount != 0
  }

  @ViewBuilder var aggregateSummaryContent: some View {
    if aggregateNeedsYouCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateNeedsYouCount)",
        label: "Needs You",
        systemImage: TaskBoardInboxLane.needsYou.systemImage,
        tint: taskBoardLaneColor(for: .needsYou)
      )
    }
    if aggregateOpenCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateOpenCount)",
        label: "Open",
        systemImage: "rectangle.stack",
        tint: HarnessMonitorTheme.secondaryInk
      )
    }
    if aggregateReviewCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateReviewCount)",
        label: "Review",
        systemImage: TaskBoardInboxLane.review.systemImage,
        tint: taskBoardLaneColor(for: .review)
      )
    }
    if aggregateBlockedCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateBlockedCount)",
        label: "Blocked",
        systemImage: TaskBoardInboxLane.blocked.systemImage,
        tint: taskBoardLaneColor(for: .blocked)
      )
    }
    if aggregateDoneCount != 0 {
      TaskBoardSummaryPill(
        value: "\(aggregateDoneCount)",
        label: "Done",
        systemImage: TaskBoardInboxLane.done.systemImage,
        tint: taskBoardLaneColor(for: .done)
      )
    }
  }

  @ViewBuilder
  func evaluationSummaryContent(_ summary: TaskBoardEvaluationSummary) -> some View {
    TaskBoardSummaryPill(
      value: "\(summary.evaluated)/\(summary.total)",
      label: "Evaluated",
      systemImage: "checkmark.seal",
      tint: HarnessMonitorTheme.secondaryInk
    )
    if summary.updated != 0 {
      TaskBoardSummaryPill(
        value: "\(summary.updated)",
        label: "Updated",
        systemImage: "arrow.triangle.2.circlepath",
        tint: HarnessMonitorTheme.accent
      )
    }
    if summary.failed + summary.blocked != 0 {
      TaskBoardSummaryPill(
        value: "\(summary.failed + summary.blocked)",
        label: "Blocked",
        systemImage: TaskBoardInboxLane.blocked.systemImage,
        tint: HarnessMonitorTheme.danger
      )
    }
  }

  static func sortedTaskBoardItems(_ items: [TaskBoardItem]) -> [TaskBoardItem] {
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

  static func priorityRank(_ priority: TaskBoardPriority) -> Int {
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

  static func sortedDecisions(_ decisions: [Decision]) -> [Decision] {
    decisions
      .filter { $0.statusRaw == "open" }
      .sorted { left, right in
        if severityRank(left.severityRaw) != severityRank(right.severityRaw) {
          return severityRank(left.severityRaw) > severityRank(right.severityRaw)
        }
        return left.createdAt < right.createdAt
      }
  }

  static func severityRank(_ severity: String) -> Int {
    switch DecisionSeverity(rawValue: severity) {
    case .critical:
      3
    case .needsUser:
      2
    case .warn:
      1
    case .info:
      0
    case .none:
      0
    }
  }
}
