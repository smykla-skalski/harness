import SwiftUI

struct MonitorAdaptiveGridLayout: Layout {
  let minimumColumnWidth: CGFloat
  let maximumColumns: Int
  let spacing: CGFloat

  init(
    minimumColumnWidth: CGFloat,
    maximumColumns: Int,
    spacing: CGFloat = 16
  ) {
    self.minimumColumnWidth = minimumColumnWidth
    self.maximumColumns = maximumColumns
    self.spacing = spacing
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    let columns = resolvedColumnCount(width: proposal.width, itemCount: subviews.count)
    let columnWidth = resolvedColumnWidth(width: proposal.width, columns: columns)
    let rowHeights = measuredRowHeights(
      subviews: subviews, columns: columns, columnWidth: columnWidth)
    let rowSpacing = CGFloat(max(rowHeights.count - 1, 0)) * spacing
    let height = rowHeights.reduce(0, +) + rowSpacing
    let width =
      proposal.width
      ?? (CGFloat(columns) * columnWidth) + (CGFloat(max(columns - 1, 0)) * spacing)

    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    let columns = resolvedColumnCount(width: bounds.width, itemCount: subviews.count)
    let columnWidth = resolvedColumnWidth(width: bounds.width, columns: columns)
    let rowHeights = measuredRowHeights(
      subviews: subviews, columns: columns, columnWidth: columnWidth)
    var y = bounds.minY

    for rowIndex in 0..<rowHeights.count {
      let rowHeight = rowHeights[rowIndex]
      let rowStart = rowIndex * columns
      let rowEnd = min(rowStart + columns, subviews.count)

      for index in rowStart..<rowEnd {
        let columnIndex = index - rowStart
        let x = bounds.minX + (CGFloat(columnIndex) * (columnWidth + spacing))
        subviews[index].place(
          at: CGPoint(x: x, y: y),
          anchor: .topLeading,
          proposal: ProposedViewSize(width: columnWidth, height: rowHeight)
        )
      }

      y += rowHeight + spacing
    }
  }

  private func resolvedColumnCount(width: CGFloat?, itemCount: Int) -> Int {
    guard itemCount > 0 else {
      return 1
    }

    guard let width, width > 0 else {
      return min(maximumColumns, itemCount)
    }

    let candidate = Int((width + spacing) / (minimumColumnWidth + spacing))
    return max(1, min(min(candidate, itemCount), maximumColumns))
  }

  private func resolvedColumnWidth(width: CGFloat?, columns: Int) -> CGFloat {
    guard let width, width > 0 else {
      return minimumColumnWidth
    }

    let gutterWidth = CGFloat(max(columns - 1, 0)) * spacing
    return (width - gutterWidth) / CGFloat(columns)
  }

  private func measuredRowHeights(
    subviews: Subviews,
    columns: Int,
    columnWidth: CGFloat
  ) -> [CGFloat] {
    guard !subviews.isEmpty else {
      return []
    }

    var rowHeights: [CGFloat] = []
    var currentRowHeight: CGFloat = 0

    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
      currentRowHeight = max(currentRowHeight, size.height)

      let isRowEnd = ((index + 1) % columns) == 0 || index == (subviews.count - 1)
      if isRowEnd {
        rowHeights.append(currentRowHeight)
        currentRowHeight = 0
      }
    }

    return rowHeights
  }
}
