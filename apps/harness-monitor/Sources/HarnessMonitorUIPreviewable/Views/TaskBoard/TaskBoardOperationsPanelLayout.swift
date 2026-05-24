import SwiftUI

struct TaskBoardOperationsPanelLayout<SyncCard: View, DispatchCard: View, InventoryCard: View>:
  View
{
  let metrics: TaskBoardOverviewMetrics
  let syncCard: SyncCard
  let dispatchCard: DispatchCard
  let inventoryCard: InventoryCard

  var body: some View {
    TaskBoardOperationsResponsiveLayout(
      minColumnWidth: metrics.operationsCardMinWidth,
      maxColumnWidth: metrics.operationsCardMaxWidth,
      spacing: metrics.columnSpacing
    ) {
      syncCard
      dispatchCard
      inventoryCard
    }
  }
}

private struct TaskBoardOperationsResponsiveLayout: Layout {
  let minColumnWidth: CGFloat
  let maxColumnWidth: CGFloat
  let spacing: CGFloat

  private var horizontalMinWidth: CGFloat {
    minColumnWidth * 3 + spacing * 2
  }

  private var horizontalMaxWidth: CGFloat {
    max(minColumnWidth, maxColumnWidth) * 3 + spacing * 2
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    guard let width = proposal.width else {
      return horizontalSize(proposalWidth: horizontalMaxWidth, subviews: subviews)
    }
    if width >= horizontalMinWidth {
      return horizontalSize(proposalWidth: width, subviews: subviews)
    }
    return verticalSize(proposalWidth: width, subviews: subviews)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    if bounds.width >= horizontalMinWidth {
      placeHorizontal(in: bounds, subviews: subviews)
    } else {
      placeVertical(in: bounds, subviews: subviews)
    }
  }

  private func horizontalSize(proposalWidth: CGFloat, subviews: Subviews) -> CGSize {
    let layoutWidth = horizontalLayoutWidth(for: proposalWidth)
    let columnWidth = horizontalColumnWidth(for: layoutWidth, count: subviews.count)
    let heights = subviews.map { subview in
      subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
    }
    return CGSize(width: proposalWidth, height: heights.max() ?? 0)
  }

  private func verticalSize(proposalWidth: CGFloat, subviews: Subviews) -> CGSize {
    let heights = subviews.map { subview in
      subview.sizeThatFits(ProposedViewSize(width: proposalWidth, height: nil)).height
    }
    let totalSpacing = spacing * CGFloat(max(subviews.count - 1, 0))
    return CGSize(width: proposalWidth, height: heights.reduce(0, +) + totalSpacing)
  }

  private func placeHorizontal(in bounds: CGRect, subviews: Subviews) {
    let layoutWidth = horizontalLayoutWidth(for: bounds.width)
    let columnWidth = horizontalColumnWidth(for: layoutWidth, count: subviews.count)
    let leadingX = bounds.midX - (layoutWidth / 2)
    for (index, subview) in subviews.enumerated() {
      let x = leadingX + CGFloat(index) * (columnWidth + spacing)
      subview.place(
        at: CGPoint(x: x, y: bounds.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: columnWidth, height: bounds.height)
      )
    }
  }

  private func placeVertical(in bounds: CGRect, subviews: Subviews) {
    var y = bounds.minY
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      subview.place(
        at: CGPoint(x: bounds.minX, y: y),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: size.height)
      )
      y += size.height + spacing
    }
  }

  private func horizontalLayoutWidth(for availableWidth: CGFloat) -> CGFloat {
    max(availableWidth, horizontalMinWidth)
  }

  private func horizontalColumnWidth(for width: CGFloat, count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    let totalSpacing = spacing * CGFloat(max(count - 1, 0))
    return max(minColumnWidth, (width - totalSpacing) / CGFloat(count))
  }
}
