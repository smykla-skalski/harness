import SwiftUI

struct TaskBoardAutomationQueueMap: View, Equatable {
  let lanes: [TaskBoardAutomationQueueLane]
  let fontScale: CGFloat

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var valueFont: Font {
    HarnessMonitorTextSize.scaledFont(.title3.monospacedDigit().weight(.bold), by: fontScale)
  }

  var body: some View {
    queueBar
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Live automation queue")
  }

  private var queueBar: some View {
    TaskBoardAutomationQueueBarLayout(spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(lanes) { lane in
        ForEach(lane.stages) { stage in
          stageView(stage, lane: lane.id)
        }
      }
    }
  }

  private func stageView(
    _ stage: TaskBoardAutomationQueueStage,
    lane: TaskBoardAutomationQueueLaneID
  ) -> some View {
    let tint = stage.value == 0 ? HarnessMonitorTheme.secondaryInk : stage.tone.color
    return VStack(spacing: HarnessMonitorTheme.spacingXS) {
      TaskBoardAutomationVerticalLabelLayout {
        Text(stage.label)
          .font(labelFont)
          .fixedSize()
          .rotationEffect(.degrees(-90))
      }

      Text(stage.value, format: .number)
        .font(valueFont)
    }
    .foregroundStyle(stage.value == 0 ? HarnessMonitorTheme.secondaryInk : tint)
    .padding(.horizontal, HarnessMonitorTheme.spacingXS)
    .padding(.top, HarnessMonitorTheme.spacingMD)
    .padding(.bottom, HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
        .fill(tint.opacity(stage.value == 0 ? 0.04 : 0.13))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
        .stroke(tint.opacity(stage.value == 0 ? 0.16 : 0.36), lineWidth: 1)
    }
    .help("\(lane.title): \(stage.label) \(stage.value)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(lane.title), \(stage.label)")
    .accessibilityValue("\(stage.value)")
  }
}

private struct TaskBoardAutomationQueueBarLayout: Layout {
  let spacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    guard !subviews.isEmpty else { return .zero }
    let cellWidth = resolvedCellWidth(proposal.width, count: subviews.count)
    let sizes = subviews.map {
      $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil))
    }
    let width =
      proposal.width
      ?? sizes.reduce(CGFloat.zero) { $0 + $1.width } + spacing * CGFloat(subviews.count - 1)
    return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    guard !subviews.isEmpty else { return }
    let cellWidth = resolvedCellWidth(bounds.width, count: subviews.count) ?? 0
    for (index, subview) in subviews.enumerated() {
      let x = bounds.minX + CGFloat(index) * (cellWidth + spacing)
      subview.place(
        at: CGPoint(x: x, y: bounds.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: cellWidth, height: bounds.height)
      )
    }
  }

  private func resolvedCellWidth(_ width: CGFloat?, count: Int) -> CGFloat? {
    width.map { max(0, ($0 - spacing * CGFloat(count - 1)) / CGFloat(count)) }
  }
}

private struct TaskBoardAutomationVerticalLabelLayout: Layout {
  func sizeThatFits(
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    let size = subview.sizeThatFits(.unspecified)
    return CGSize(width: size.height, height: size.width)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    subviews.first?.place(
      at: CGPoint(x: bounds.midX, y: bounds.midY),
      anchor: .center,
      proposal: .unspecified
    )
  }
}

extension TaskBoardAutomationQueueLaneID {
  fileprivate var title: String {
    switch self {
    case .waiting: "Waiting"
    case .execution: "Execution"
    case .recovery: "Recovery"
    }
  }
}
