import HarnessMonitorKit
import SwiftUI

struct TaskBoardOverviewMetrics: Equatable {
  let controlMinHeight: CGFloat
  let iconControlMinWidth: CGFloat
  let managementPanelMinHeight: CGFloat
  let managementPanelSpacing: CGFloat
  let managementPanelCornerRadius: CGFloat
  let operationsCardMinWidth: CGFloat
  let operationsCardMaxWidth: CGFloat
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
    operationsCardMinWidth = max(280, 320 * min(scale, 1.15))
    operationsCardMaxWidth = max(560, 620 * min(scale, 1.1))
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

  // Pills are rendered in dense clusters across the dashboard
  // (`TaskBoardOperationsPanel` lays them out as Items / Providers /
  // Ops / Plans summary chips, repeated per row). Each `.scaledFont`
  // call plants a `ScaledFontModifier` that subscribes per text node
  // to `\.fontScale`, and r17 traced this as a contributor to the
  // `Conditional View Value square.split.diagonal` 18,956-edge
  // self-loop fanned via `EnvironmentWriter: Font?`. Subscribe once
  // and apply precomputed fonts.
  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var captionBold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.bold), by: fontScale)
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
    let captionFont = captionFont
    let captionSemibold = captionSemibold
    let captionBold = captionBold
    return HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(captionSemibold)
          .accessibilityHidden(true)
      }
      Text(label)
        .font(captionFont)
      Text(value)
        .font(captionBold)
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
  @Environment(\.fontScale)
  private var fontScale

  private var headerFont: Font {
    HarnessMonitorTextSize.scaledFont(.headline.weight(.semibold), by: fontScale)
  }

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .font(headerFont)
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
    cachedPresentation.apiItems(in: .review).count
  }

  var taskBoardNeedsYouCount: Int {
    cachedPresentation.apiItems(in: .needsYou).count
  }

  var taskBoardBlockedCount: Int {
    cachedPresentation.apiItems(in: .blocked).count
  }

  var taskBoardDoneCount: Int {
    cachedPresentation.apiItems(in: .done).count
  }

  var aggregateNeedsYouCount: Int {
    cachedPresentation.aggregateNeedsYouCount
  }

  var aggregateOpenCount: Int {
    cachedPresentation.aggregateOpenCount
  }

  var aggregateReviewCount: Int {
    cachedPresentation.aggregateReviewCount
  }

  var aggregateBlockedCount: Int {
    cachedPresentation.aggregateBlockedCount
  }

  var aggregateDoneCount: Int {
    cachedPresentation.aggregateDoneCount
  }

  var hasAggregateSummary: Bool {
    cachedPresentation.hasAggregateSummary
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
}
