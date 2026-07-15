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
    operationsCardMinWidth = max(260, 300 * min(scale, 1.15))
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

struct TaskBoardLaneStripSizing: Equatable {
  let minColumnWidth: CGFloat
  let spacing: CGFloat
  let collapsedColumnWidth: CGFloat

  init(
    minColumnWidth: CGFloat,
    spacing: CGFloat,
    collapsedColumnWidth: CGFloat = 72
  ) {
    self.minColumnWidth = minColumnWidth
    self.spacing = spacing
    self.collapsedColumnWidth = collapsedColumnWidth
  }

  func minimumWidth(for columnCount: Int) -> CGFloat {
    guard columnCount > 0 else { return 0 }
    return minColumnWidth * CGFloat(columnCount) + totalSpacing(for: columnCount)
  }

  func resolvedWidth(for availableWidth: CGFloat?, columnCount: Int) -> CGFloat {
    max(availableWidth ?? 0, minimumWidth(for: columnCount))
  }

  func columnWidth(for availableWidth: CGFloat?, columnCount: Int) -> CGFloat {
    guard columnCount > 0 else { return 0 }
    let resolvedWidth = resolvedWidth(for: availableWidth, columnCount: columnCount)
    return max(
      minColumnWidth,
      (resolvedWidth - totalSpacing(for: columnCount)) / CGFloat(columnCount)
    )
  }

  func minimumWidth(for preferredWidths: [CGFloat]) -> CGFloat {
    guard !preferredWidths.isEmpty else { return 0 }
    return preferredWidths.reduce(0, +) + totalSpacing(for: preferredWidths.count)
  }

  func resolvedWidth(for availableWidth: CGFloat?, preferredWidths: [CGFloat]) -> CGFloat {
    max(availableWidth ?? 0, minimumWidth(for: preferredWidths))
  }

  func columnWidths(
    for availableWidth: CGFloat?,
    preferredWidths: [CGFloat],
    canExpand: [Bool]
  ) -> [CGFloat] {
    guard !preferredWidths.isEmpty else { return [] }
    let preferredWidths = preferredWidths.map { max(0, $0) }
    let resolvedWidth = resolvedWidth(for: availableWidth, preferredWidths: preferredWidths)
    let extraWidth = max(0, resolvedWidth - minimumWidth(for: preferredWidths))
    guard extraWidth > 0 else {
      return preferredWidths
    }

    let expandableIndices = preferredWidths.indices.filter { index in
      canExpand.indices.contains(index) ? canExpand[index] : true
    }
    guard !expandableIndices.isEmpty else {
      return preferredWidths
    }

    let extraPerColumn = extraWidth / CGFloat(expandableIndices.count)
    return preferredWidths.indices.map { index in
      if expandableIndices.contains(index) {
        return preferredWidths[index] + extraPerColumn
      }
      return preferredWidths[index]
    }
  }

  private func totalSpacing(for columnCount: Int) -> CGFloat {
    spacing * CGFloat(max(columnCount - 1, 0))
  }
}

struct TaskBoardLanePreferredWidthKey: LayoutValueKey {
  static let defaultValue: CGFloat? = nil
}

struct TaskBoardLaneCanExpandKey: LayoutValueKey {
  static let defaultValue = true
}

/// Wraps a single subview so the dashboard task-board content reports
/// `max(intrinsic, viewportHeight)` to its parent `ScrollView`.
///
/// The lane chrome uses `idealHeight: laneFixedHeight`, so the subview's
/// intrinsic height in an unbounded context is `chrome + laneFixedHeight + ...`.
/// When the viewport exceeds that intrinsic, this layout proposes the larger
/// viewport-sized bounds back to the subview, which lets the `.frame(maxHeight:
/// .infinity)` chain inside `TaskBoardOverviewView` expand lanes into the
/// leftover space. When the viewport is smaller, the layout reports the
/// intrinsic and the parent `ScrollView` activates so chrome + lane minimum
/// stays reachable.
struct TaskBoardDashboardViewportLayout: Layout {
  let viewportHeight: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    let intrinsic = subview.sizeThatFits(
      ProposedViewSize(width: proposal.width, height: nil)
    )
    let width = proposal.width ?? intrinsic.width
    let height = max(intrinsic.height, max(viewportHeight, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    guard let subview = subviews.first else { return }
    subview.place(
      at: CGPoint(x: bounds.minX, y: bounds.minY),
      anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
    )
  }
}

struct TaskBoardLaneStripLayout: Layout {
  let sizing: TaskBoardLaneStripSizing

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    let columnCount = subviews.count
    guard columnCount > 0 else { return .zero }

    let preferredWidths = preferredWidths(for: subviews)
    let canExpand = canExpandValues(for: subviews)
    let columnWidths = sizing.columnWidths(
      for: proposal.width,
      preferredWidths: preferredWidths,
      canExpand: canExpand
    )
    let measuredHeight =
      zip(subviews, columnWidths).map { subview, columnWidth in
        subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
      }.max() ?? 0
    let height = max(measuredHeight, proposal.height ?? 0)

    return CGSize(
      width: sizing.resolvedWidth(for: proposal.width, preferredWidths: preferredWidths),
      height: height
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    let columnCount = subviews.count
    guard columnCount > 0 else { return }

    let columnWidths = sizing.columnWidths(
      for: bounds.width,
      preferredWidths: preferredWidths(for: subviews),
      canExpand: canExpandValues(for: subviews)
    )
    var x = bounds.minX
    for (subview, columnWidth) in zip(subviews, columnWidths) {
      subview.place(
        at: CGPoint(x: x, y: bounds.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: columnWidth, height: bounds.height)
      )
      x += columnWidth + sizing.spacing
    }
  }

  private func preferredWidths(for subviews: Subviews) -> [CGFloat] {
    subviews.map { subview in
      subview[TaskBoardLanePreferredWidthKey.self] ?? sizing.minColumnWidth
    }
  }

  private func canExpandValues(for subviews: Subviews) -> [Bool] {
    subviews.map { subview in
      subview[TaskBoardLaneCanExpandKey.self]
    }
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
  private var iconFont: Font {
    HarnessMonitorTextSize.scaledFont(.system(size: 8.6, weight: .semibold), by: fontScale)
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
    let iconFont = iconFont
    let captionBold = captionBold
    return HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingXS) {
      if let systemImage {
        Text(Image(systemName: systemImage))
          .font(iconFont)
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

  static func runOnceRequest(
    for item: TaskBoardItem,
    dryRun: Bool? = nil
  ) -> TaskBoardOrchestratorRunOnceRequest {
    TaskBoardOrchestratorRunOnceRequest(itemId: item.id, dryRun: dryRun, status: item.status)
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
    case .umbrella, .todo, .planning:
      .open
    case .inProgress:
      .inProgress
    case .toReview:
      .awaitingReview
    case .inReview:
      .inReview
    case .failed:
      .blocked
    case .agenticReview, .testing, .humanRequired:
      nil
    }
  }

  var taskBoardDropStatus: TaskBoardStatus {
    switch self {
    case .umbrella:
      .umbrella
    case .todo:
      .todo
    case .planning:
      .planning
    case .inProgress:
      .inProgress
    case .agenticReview:
      .agenticReview
    case .testing:
      .testing
    case .inReview:
      .inReview
    case .toReview:
      .toReview
    case .humanRequired:
      .humanRequired
    case .failed:
      .failed
    }
  }

  func taskBoardDropStatus(for _: TaskBoardItem) -> TaskBoardStatus {
    taskBoardDropStatus
  }
}
