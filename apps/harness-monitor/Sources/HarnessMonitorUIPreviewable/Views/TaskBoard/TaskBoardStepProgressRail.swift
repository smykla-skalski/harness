import SwiftUI

/// The board-lifecycle progress rail for Step Mode: Todo through Done, with the
/// current column highlighted. Each node is tappable to read that stage ahead.
struct TaskBoardStepProgressRail: View {
  let current: TaskBoardStepColumn?
  let isBlocked: Bool
  let viewing: TaskBoardStepColumn?
  let state: TaskBoardStepRailState

  @Environment(\.fontScale)
  private var fontScale

  private var numberFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.bold().monospacedDigit(), by: fontScale)
  }
  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  private var badgeSide: CGFloat {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    return max(28, 28 * min(scale, 1.4))
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXS) {
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
      state.viewingColumn = state.viewingColumn == column ? nil : column
    } label: {
      VStack(spacing: HarnessMonitorTheme.spacingXS) {
        badge(nodeState, column: column)
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

  private func badge(_ nodeState: TaskBoardStepNodeState, column: TaskBoardStepColumn) -> some View {
    ZStack {
      Circle().fill(fillColor(nodeState))
      Circle().strokeBorder(borderColor(nodeState), lineWidth: column == viewing ? 2.5 : 1.5)
      badgeGlyph(nodeState, order: column.order)
    }
    .frame(width: badgeSide, height: badgeSide)
  }

  @ViewBuilder
  private func badgeGlyph(_ nodeState: TaskBoardStepNodeState, order: Int) -> some View {
    switch nodeState {
    case .done:
      Image(systemName: "checkmark").font(numberFont).foregroundStyle(HarnessMonitorTheme.success)
    case .failed:
      Image(systemName: "exclamationmark").font(numberFont).foregroundStyle(HarnessMonitorTheme.danger)
    case .current:
      Text("\(order + 1)").font(numberFont).foregroundStyle(HarnessMonitorTheme.accent)
    case .upcoming:
      Text("\(order + 1)").font(numberFont).foregroundStyle(.secondary)
    }
  }

  private func fillColor(_ nodeState: TaskBoardStepNodeState) -> Color {
    switch nodeState {
    case .done: HarnessMonitorTheme.success.opacity(0.16)
    case .current: HarnessMonitorTheme.accent.opacity(0.16)
    case .upcoming: HarnessMonitorTheme.ink.opacity(0.04)
    case .failed: HarnessMonitorTheme.danger.opacity(0.16)
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
