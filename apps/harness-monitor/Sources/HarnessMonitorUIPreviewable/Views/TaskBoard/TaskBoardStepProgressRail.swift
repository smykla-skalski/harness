import SwiftUI

/// The board-lifecycle progress rail for Step Mode: Todo through Done drawn as
/// one connected vertical track beside the stage detail. The flow's current
/// column is highlighted and each node is tappable to read that stage ahead.
struct TaskBoardStepProgressRail: View {
  let current: TaskBoardStepColumn?
  let isBlocked: Bool
  let viewing: TaskBoardStepColumn?
  let state: TaskBoardStepRailState
  /// Dropped when the panel is too narrow to seat titles next to the detail
  /// column. The track keeps its badges, tooltips, and accessibility labels.
  var showsTitles = true

  @Environment(\.fontScale)
  private var fontScale

  private var glyphFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.bold().monospacedDigit(), by: fontScale)
  }
  private var badgeSide: CGFloat { Self.badgeSide(for: fontScale) }

  /// Also the rail's whole width once titles drop out, so the panel can place
  /// its separator without reaching inside this view.
  static func badgeSide(for fontScale: CGFloat) -> CGFloat {
    26 * max(1, min(SessionWindowFontScale.metricsScale(for: fontScale), 1.4))
  }
  /// Track length between two badges, and the same value as each row's bottom
  /// gap, so the rhythm holds whether or not a title wraps.
  private var rowGap: CGFloat { HarnessMonitorTheme.spacingMD }
  private var lastOrder: Int { TaskBoardStepColumn.allCases.count - 1 }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
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
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        badge(nodeState, column: column)
        if showsTitles {
          title(nodeState, column: column)
        }
      }
      .padding(.bottom, column.order == lastOrder ? 0 : rowGap)
      .background(alignment: .topLeading) { segment(column) }
      .contentShape(.rect)
    }
    .harnessActionButtonStyle(variant: .borderless)
    // Hovering reads the stage without leaving the current one, and it is the
    // only way to name a node once titles drop out at narrow widths.
    .help("\(column.title): \(column.explanation)")
    .accessibilityLabel("\(column.title), \(nodeState.accessibilityDescription)")
    .accessibilityHint("Reads what this stage does")
    .accessibilityAddTraits(column == viewing ? [.isButton, .isSelected] : .isButton)
  }

  /// A single-line title sits centred against its badge; a wrapped one grows the
  /// row and the segment behind it stretches to match.
  private func title(
    _ nodeState: TaskBoardStepNodeState,
    column: TaskBoardStepColumn
  ) -> some View {
    Text(column.title)
      .font(titleFont(nodeState))
      .foregroundStyle(titleColor(nodeState))
      .lineLimit(2)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, minHeight: badgeSide, alignment: .leading)
  }

  /// The track carrying down to the next badge. It rides in a background rather
  /// than beside the badge in a stack: a Capsule is flexible in both axes, and
  /// as a stack sibling it made the whole rail vertically greedy, so the panel
  /// stretched to whatever height the window offered. SwiftUI hands a background
  /// the row's already-resolved size, so it cannot feed back into that size.
  @ViewBuilder
  private func segment(_ column: TaskBoardStepColumn) -> some View {
    if column.order != lastOrder {
      Capsule()
        .fill(segmentColor(filled: passed(column.order)))
        .frame(width: 2)
        .frame(maxHeight: .infinity)
        .padding(.top, badgeSide)
        .frame(width: badgeSide)
        .accessibilityHidden(true)
    }
  }

  private func segmentColor(filled: Bool) -> Color {
    filled ? HarnessMonitorTheme.success : HarnessMonitorTheme.ink.opacity(0.15)
  }

  /// The flow has moved past this node, so its outgoing segment is complete.
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
        .font(glyphFont)
        .foregroundStyle(HarnessMonitorTheme.success)
    case .failed:
      Image(systemName: "exclamationmark")
        .font(glyphFont)
        .foregroundStyle(HarnessMonitorTheme.danger)
    case .current:
      Text("\(order + 1)").font(glyphFont).foregroundStyle(HarnessMonitorTheme.accent)
    case .upcoming:
      Text("\(order + 1)").font(glyphFont).foregroundStyle(.secondary)
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

  private func titleFont(_ nodeState: TaskBoardStepNodeState) -> Font {
    let base: Font =
      switch nodeState {
      case .current, .failed: .callout.weight(.semibold)
      case .done, .upcoming: .callout
      }
    return HarnessMonitorTextSize.scaledFont(base, by: fontScale)
  }

  private func titleColor(_ nodeState: TaskBoardStepNodeState) -> Color {
    switch nodeState {
    case .current: .primary
    case .failed: HarnessMonitorTheme.danger
    case .done, .upcoming: .secondary
    }
  }
}
