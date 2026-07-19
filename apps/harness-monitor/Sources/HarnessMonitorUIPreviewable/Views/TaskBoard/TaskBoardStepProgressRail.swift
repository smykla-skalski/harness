import SwiftUI

/// The board-lifecycle progress rail for Step Mode: Todo through Done drawn as
/// one connected track. The flow's current column is highlighted and each node
/// is tappable to read that stage ahead.
struct TaskBoardStepProgressRail: View {
  let current: TaskBoardStepColumn?
  let isBlocked: Bool
  let viewing: TaskBoardStepColumn?
  let state: TaskBoardStepRailState

  @Environment(\.fontScale)
  private var fontScale

  private var numberFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.bold().monospacedDigit(), by: fontScale)
  }
  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  private var badgeSide: CGFloat {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    return max(32, 32 * min(scale, 1.4))
  }
  private var lastOrder: Int { TaskBoardStepColumn.allCases.count - 1 }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(TaskBoardStepColumn.allCases) { column in
        node(column)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.step.progress-rail")
  }

  private func node(_ column: TaskBoardStepColumn) -> some View {
    let nodeState = column.nodeState(current: current, isBlocked: isBlocked)
    return Button {
      // Tapping the current node (or the one already previewed) exits preview;
      // any other node previews that stage.
      state.viewingColumn = (column == current || state.viewingColumn == column) ? nil : column
    } label: {
      VStack(spacing: HarnessMonitorTheme.spacingSM) {
        ZStack {
          connector(order: column.order)
          badge(nodeState, column: column)
        }
        .frame(height: badgeSide)
        Text(column.title)
          .font(titleFont)
          .foregroundStyle(titleColor(nodeState))
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity)
      .contentShape(.rect)
    }
    .harnessActionButtonStyle(variant: .borderless)
    .accessibilityLabel("\(column.title), \(nodeState.accessibilityDescription)")
    .accessibilityHint("Reads what this stage does")
    .accessibilityAddTraits(column == viewing ? [.isButton, .isSelected] : .isButton)
  }

  /// The track behind the badge: a leading and trailing half-segment split by a
  /// clear gap for the badge, so adjacent nodes join into one continuous line.
  private func connector(order: Int) -> some View {
    HStack(spacing: 0) {
      connectorSegment(filled: reached(order), hidden: order == 0)
      Color.clear.frame(width: badgeSide)
      connectorSegment(filled: passed(order), hidden: order == lastOrder)
    }
    .accessibilityHidden(true)
  }

  private func connectorSegment(filled: Bool, hidden: Bool) -> some View {
    Capsule()
      .fill(segmentColor(filled: filled, hidden: hidden))
      .frame(height: 2)
      .frame(maxWidth: .infinity)
  }

  private func segmentColor(filled: Bool, hidden: Bool) -> Color {
    if hidden { return .clear }
    return filled ? HarnessMonitorTheme.success : HarnessMonitorTheme.ink.opacity(0.15)
  }

  /// The flow has arrived at this node, so its leading segment is complete.
  private func reached(_ order: Int) -> Bool {
    guard let current else { return false }
    return current.order >= order
  }

  /// The flow has moved past this node, so its trailing segment is complete.
  private func passed(_ order: Int) -> Bool {
    guard let current else { return false }
    return current.order > order
  }

  private func badge(
    _ nodeState: TaskBoardStepNodeState,
    column: TaskBoardStepColumn
  ) -> some View {
    ZStack {
      Circle().fill(fillColor(nodeState))
      Circle()
        .strokeBorder(borderColor(nodeState), lineWidth: ringWidth(nodeState, column: column))
      badgeGlyph(nodeState, order: column.order)
    }
    .frame(width: badgeSide, height: badgeSide)
  }

  private func ringWidth(
    _ nodeState: TaskBoardStepNodeState,
    column: TaskBoardStepColumn
  ) -> CGFloat {
    if column == viewing { return 2.5 }
    switch nodeState {
    case .current, .failed: return 2
    case .done, .upcoming: return 1.5
    }
  }

  @ViewBuilder
  private func badgeGlyph(_ nodeState: TaskBoardStepNodeState, order: Int) -> some View {
    switch nodeState {
    case .done:
      Image(systemName: "checkmark")
        .font(numberFont)
        .foregroundStyle(HarnessMonitorTheme.success)
    case .failed:
      Image(systemName: "exclamationmark")
        .font(numberFont)
        .foregroundStyle(HarnessMonitorTheme.danger)
    case .current:
      Text("\(order + 1)").font(numberFont).foregroundStyle(HarnessMonitorTheme.accent)
    case .upcoming:
      Text("\(order + 1)").font(numberFont).foregroundStyle(.secondary)
    }
  }

  private func fillColor(_ nodeState: TaskBoardStepNodeState) -> Color {
    switch nodeState {
    case .done: HarnessMonitorTheme.success.opacity(0.18)
    case .current: HarnessMonitorTheme.accent.opacity(0.22)
    case .upcoming: HarnessMonitorTheme.ink.opacity(0.05)
    case .failed: HarnessMonitorTheme.danger.opacity(0.20)
    }
  }

  private func borderColor(_ nodeState: TaskBoardStepNodeState) -> Color {
    switch nodeState {
    case .done: HarnessMonitorTheme.success
    case .current: HarnessMonitorTheme.accent
    case .upcoming: HarnessMonitorTheme.secondaryInk.opacity(0.35)
    case .failed: HarnessMonitorTheme.danger
    }
  }

  private func titleColor(_ nodeState: TaskBoardStepNodeState) -> Color {
    switch nodeState {
    case .current: .primary
    case .failed: HarnessMonitorTheme.danger
    case .done, .upcoming: .secondary
    }
  }
}
