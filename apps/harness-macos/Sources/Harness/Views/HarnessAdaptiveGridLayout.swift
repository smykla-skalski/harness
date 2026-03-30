import SwiftUI

struct HarnessAdaptiveGridLayout: Layout {
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

  private var safeMinimumColumnWidth: CGFloat {
    guard minimumColumnWidth.isFinite, minimumColumnWidth > 0 else {
      return 1
    }
    return minimumColumnWidth
  }

  private var safeMaximumColumns: Int {
    max(maximumColumns, 1)
  }

  private var safeSpacing: CGFloat {
    guard spacing.isFinite, spacing >= 0 else {
      return 0
    }
    return spacing
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    let columns = resolvedColumnCount(width: proposal.width, itemCount: subviews.count)
    let rowHeights = measuredRowHeights(
      subviews: subviews,
      width: proposal.width,
      columns: columns
    )
    let rowSpacing = CGFloat(max(rowHeights.count - 1, 0)) * safeSpacing
    let height = rowHeights.reduce(0, +) + rowSpacing
    let width =
      proposal.width
      ?? resolvedColumnWidth(width: nil, columns: columns) * CGFloat(columns)
      + CGFloat(max(columns - 1, 0)) * safeSpacing

    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    let columns = resolvedColumnCount(width: bounds.width, itemCount: subviews.count)
    let rowHeights = measuredRowHeights(
      subviews: subviews,
      width: bounds.width,
      columns: columns
    )
    var y = bounds.minY

    for rowIndex in 0..<rowHeights.count {
      let rowHeight = rowHeights[rowIndex]
      let rowStart = rowIndex * columns
      let rowEnd = min(rowStart + columns, subviews.count)
      let rowColumns = rowEnd - rowStart
      let columnWidth = resolvedColumnWidth(width: bounds.width, columns: rowColumns)

      for index in rowStart..<rowEnd {
        let columnIndex = index - rowStart
        let x = bounds.minX + (CGFloat(columnIndex) * (columnWidth + safeSpacing))
        subviews[index].place(
          at: CGPoint(x: x, y: y),
          anchor: .topLeading,
          proposal: ProposedViewSize(width: columnWidth, height: rowHeight)
        )
      }

      y += rowHeight + safeSpacing
    }
  }

  private func resolvedColumnCount(width: CGFloat?, itemCount: Int) -> Int {
    guard itemCount > 0 else {
      return 1
    }

    guard let width, width.isFinite, width > 0 else {
      return min(safeMaximumColumns, itemCount)
    }

    let columnStride = safeMinimumColumnWidth + safeSpacing
    guard columnStride.isFinite, columnStride > 0 else {
      return min(safeMaximumColumns, itemCount)
    }

    let candidate = ((width + safeSpacing) / columnStride).rounded(.down)
    guard candidate.isFinite, candidate > 0 else {
      return 1
    }

    return max(1, min(min(Int(candidate), itemCount), safeMaximumColumns))
  }

  private func resolvedColumnWidth(width: CGFloat?, columns: Int) -> CGFloat {
    let safeColumns = max(columns, 1)

    guard let width, width.isFinite, width > 0 else {
      return safeMinimumColumnWidth
    }

    let gutterWidth = CGFloat(max(safeColumns - 1, 0)) * safeSpacing
    let availableWidth = width - gutterWidth
    guard availableWidth.isFinite, availableWidth > 0 else {
      return safeMinimumColumnWidth
    }

    return availableWidth / CGFloat(safeColumns)
  }

  private func measuredRowHeights(
    subviews: Subviews,
    width: CGFloat?,
    columns: Int,
  ) -> [CGFloat] {
    guard !subviews.isEmpty else {
      return []
    }

    var rowHeights: [CGFloat] = []
    var rowStart = 0

    while rowStart < subviews.count {
      let rowEnd = min(rowStart + columns, subviews.count)
      let rowColumns = rowEnd - rowStart
      let columnWidth = resolvedColumnWidth(width: width, columns: rowColumns)
      var rowHeight: CGFloat = 0

      for index in rowStart..<rowEnd {
        let size = subviews[index].sizeThatFits(
          ProposedViewSize(width: columnWidth, height: nil)
        )
        rowHeight = max(rowHeight, size.height)
      }

      rowHeights.append(rowHeight)
      rowStart = rowEnd
    }

    return rowHeights
  }
}
