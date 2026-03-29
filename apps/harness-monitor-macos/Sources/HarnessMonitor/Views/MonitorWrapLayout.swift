import SwiftUI

struct MonitorWrapLayout: Layout {
  let spacing: CGFloat
  let lineSpacing: CGFloat

  init(spacing: CGFloat = 8, lineSpacing: CGFloat? = nil) {
    self.spacing = spacing
    self.lineSpacing = lineSpacing ?? spacing
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    let rows = arrangedRows(
      maxWidth: proposal.width ?? .greatestFiniteMagnitude,
      subviews: subviews
    )

    guard !rows.isEmpty else {
      return .zero
    }

    let width =
      proposal.width
      ?? rows.map(\.width).max()
      ?? 0
    let totalHeight =
      rows.map(\.height).reduce(0, +)
      + CGFloat(max(rows.count - 1, 0)) * lineSpacing

    return CGSize(width: width, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    let rows = arrangedRows(maxWidth: bounds.width, subviews: subviews)
    var y = bounds.minY

    for row in rows {
      var x = bounds.minX

      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: x, y: y),
          anchor: .topLeading,
          proposal: ProposedViewSize(item.size)
        )
        x += item.size.width + spacing
      }

      y += row.height + lineSpacing
    }
  }

  private func arrangedRows(
    maxWidth: CGFloat,
    subviews: Subviews
  ) -> [MonitorWrapLayoutRow] {
    guard !subviews.isEmpty else {
      return []
    }

    let clampedWidth =
      maxWidth.isFinite && maxWidth > 0
      ? maxWidth
      : .greatestFiniteMagnitude

    var rows: [MonitorWrapLayoutRow] = []
    var currentItems: [MonitorWrapLayoutItem] = []
    var currentWidth: CGFloat = 0
    var currentHeight: CGFloat = 0

    for index in subviews.indices {
      let itemSize = measuredSize(for: subviews[index], maxWidth: clampedWidth)
      let proposedWidth =
        currentItems.isEmpty
        ? itemSize.width
        : currentWidth + spacing + itemSize.width

      if !currentItems.isEmpty && proposedWidth > clampedWidth {
        rows.append(
          MonitorWrapLayoutRow(
            items: currentItems,
            width: currentWidth,
            height: currentHeight
          )
        )
        currentItems = []
        currentWidth = 0
        currentHeight = 0
      }

      currentItems.append(
        MonitorWrapLayoutItem(
          index: index,
          size: itemSize
        )
      )
      currentWidth =
        currentItems.count == 1
        ? itemSize.width
        : currentWidth + spacing + itemSize.width
      currentHeight = max(currentHeight, itemSize.height)
    }

    if !currentItems.isEmpty {
      rows.append(
        MonitorWrapLayoutRow(
          items: currentItems,
          width: currentWidth,
          height: currentHeight
        )
      )
    }

    return rows
  }

  private func measuredSize(
    for subview: LayoutSubview,
    maxWidth: CGFloat
  ) -> CGSize {
    let intrinsicSize = subview.sizeThatFits(.unspecified)

    guard intrinsicSize.width > maxWidth else {
      return intrinsicSize
    }

    return subview.sizeThatFits(
      ProposedViewSize(width: maxWidth, height: nil)
    )
  }
}

private struct MonitorWrapLayoutRow {
  let items: [MonitorWrapLayoutItem]
  let width: CGFloat
  let height: CGFloat
}

private struct MonitorWrapLayoutItem {
  let index: Int
  let size: CGSize
}
