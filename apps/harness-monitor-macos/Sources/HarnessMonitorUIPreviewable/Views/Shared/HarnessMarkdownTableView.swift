import SwiftUI

struct HarnessMarkdownTableView: View {
  let table: HarnessMarkdownTable
  let settings: HarnessMarkdownRenderSettings
  let style: HarnessMarkdownResolvedRenderSettings

  var body: some View {
    if columnCount > 0 {
      ViewThatFits(in: .horizontal) {
        tableContent
        ScrollView(.horizontal) {
          tableContent
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollIndicators(.hidden)
      }
      .padding(HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
          .fill(style.colors.tableBackground)
      }
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
          .stroke(style.colors.tableBorder, lineWidth: 1)
      }
    }
  }

  private var tableContent: some View {
    HarnessMarkdownTableLayout(
      columnCount: columnCount,
      alignments: table.alignments,
      horizontalSpacing: style.spacing.tableColumn,
      verticalSpacing: style.spacing.tableRow
    ) {
      rowCells(table.headers, isHeader: true)
      Rectangle()
        .fill(style.colors.tableBorder)
        .frame(height: 1)
      ForEach(table.rows.indices, id: \.self) { rowIndex in
        rowCells(table.rows[rowIndex], isHeader: false)
      }
    }
  }

  @ViewBuilder
  private func rowCells(_ row: [[HarnessMarkdownInline]], isHeader: Bool) -> some View {
    ForEach(0..<columnCount, id: \.self) { column in
      HarnessMarkdownInlineFlowView(
        inlines: cell(at: column, in: row),
        style: HarnessMarkdownInlineRenderStyle(
          font: isHeader ? style.typography.tableHeader.font : style.typography.body.font,
          codeFont: style.typography.inlineCode.font,
          colors: style.colors
        ),
        images: style.images,
        imageLayout: .inline
      )
      .multilineTextAlignment(textAlignment(for: column))
    }
  }

  private var columnCount: Int {
    max(table.headers.count, table.alignments.count, table.rows.map(\.count).max() ?? 0)
  }

  private func cell(at index: Int, in row: [[HarnessMarkdownInline]]) -> [HarnessMarkdownInline] {
    index < row.count ? row[index] : []
  }

  private func textAlignment(for index: Int) -> TextAlignment {
    guard index < table.alignments.count else { return .leading }
    switch table.alignments[index] {
    case .leading:
      return .leading
    case .center:
      return .center
    case .trailing:
      return .trailing
    }
  }
}

private struct HarnessMarkdownTableLayout: Layout {
  let columnCount: Int
  let alignments: [HarnessMarkdownTable.Alignment]
  let horizontalSpacing: CGFloat
  let verticalSpacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    measure(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let measurement = measure(
      proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
    placeCells(bounds: bounds, measurement: measurement, subviews: subviews)
    placeDivider(bounds: bounds, measurement: measurement, subviews: subviews)
  }

  private func measure(proposal: ProposedViewSize, subviews: Subviews)
    -> HarnessMarkdownTableMeasurement
  {
    guard columnCount > 0, subviews.count >= columnCount else {
      return HarnessMarkdownTableMeasurement.empty
    }
    let rowCount = tableRowCount(subviews: subviews)
    let intrinsicWidths = intrinsicColumnWidths(subviews: subviews, rowCount: rowCount)
    let spacingWidth = horizontalSpacing * CGFloat(max(0, columnCount - 1))
    let intrinsicContentWidth = intrinsicWidths.reduce(0, +) + spacingWidth
    let proposedWidth = proposal.width ?? intrinsicContentWidth
    let targetWidth = max(intrinsicContentWidth, proposedWidth)
    let spareWidth = max(0, targetWidth - intrinsicContentWidth)
    let extraColumnWidth = spareWidth / CGFloat(columnCount)
    let columnWidths = intrinsicWidths.map { $0 + extraColumnWidth }
    let rowHeights = measuredRowHeights(
      subviews: subviews,
      rowCount: rowCount,
      columnWidths: columnWidths
    )
    let dividerHeight = dividerHeight(targetWidth: targetWidth, subviews: subviews)
    let positions = verticalPositions(rowHeights: rowHeights, dividerHeight: dividerHeight)
    return HarnessMarkdownTableMeasurement(
      columnWidths: columnWidths,
      rowHeights: rowHeights,
      rowY: positions.rowY,
      dividerY: positions.dividerY,
      dividerHeight: dividerHeight,
      size: CGSize(width: targetWidth, height: positions.height)
    )
  }

  private func intrinsicColumnWidths(subviews: Subviews, rowCount: Int) -> [CGFloat] {
    var widths = Array(repeating: CGFloat(0), count: columnCount)
    for row in 0..<rowCount {
      for column in 0..<columnCount {
        guard let index = cellIndex(row: row, column: column), index < subviews.count else {
          continue
        }
        let size = subviews[index].sizeThatFits(.unspecified)
        widths[column] = max(widths[column], size.width)
      }
    }
    return widths
  }

  private func measuredRowHeights(
    subviews: Subviews,
    rowCount: Int,
    columnWidths: [CGFloat]
  ) -> [CGFloat] {
    (0..<rowCount).map { row in
      var height = CGFloat(0)
      for column in 0..<columnCount {
        guard let index = cellIndex(row: row, column: column), index < subviews.count else {
          continue
        }
        let size = subviews[index].sizeThatFits(
          ProposedViewSize(width: columnWidths[column], height: nil)
        )
        height = max(height, size.height)
      }
      return height
    }
  }

  private func verticalPositions(
    rowHeights: [CGFloat],
    dividerHeight: CGFloat
  ) -> HarnessMarkdownTableVerticalPositions {
    guard !rowHeights.isEmpty else { return .empty }
    var rowY = Array(repeating: CGFloat(0), count: rowHeights.count)
    var y = rowHeights[0]
    let dividerY = y + verticalSpacing
    y = dividerY + dividerHeight
    for row in 1..<rowHeights.count {
      y += verticalSpacing
      rowY[row] = y
      y += rowHeights[row]
    }
    return HarnessMarkdownTableVerticalPositions(rowY: rowY, dividerY: dividerY, height: y)
  }

  private func placeCells(
    bounds: CGRect,
    measurement: HarnessMarkdownTableMeasurement,
    subviews: Subviews
  ) {
    for row in measurement.rowHeights.indices {
      for column in 0..<columnCount {
        guard let index = cellIndex(row: row, column: column), index < subviews.count else {
          continue
        }
        let columnWidth = measurement.columnWidths[column]
        let proposal = ProposedViewSize(width: columnWidth, height: nil)
        let size = subviews[index].sizeThatFits(proposal)
        let x =
          bounds.minX + xPosition(for: column, widths: measurement.columnWidths)
          + horizontalOffset(column: column, contentWidth: size.width, columnWidth: columnWidth)
        let y =
          bounds.minY + measurement.rowY[row]
          + max(0, (measurement.rowHeights[row] - size.height) / 2)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: proposal)
      }
    }
  }

  private func placeDivider(
    bounds: CGRect,
    measurement: HarnessMarkdownTableMeasurement,
    subviews: Subviews
  ) {
    guard let dividerY = measurement.dividerY, dividerIndex < subviews.count else { return }
    subviews[dividerIndex].place(
      at: CGPoint(x: bounds.minX, y: bounds.minY + dividerY),
      proposal: ProposedViewSize(width: measurement.size.width, height: measurement.dividerHeight)
    )
  }

  private func xPosition(for column: Int, widths: [CGFloat]) -> CGFloat {
    guard column > 0 else { return 0 }
    return widths[..<column].reduce(0, +) + horizontalSpacing * CGFloat(column)
  }

  private func horizontalOffset(column: Int, contentWidth: CGFloat, columnWidth: CGFloat) -> CGFloat
  {
    switch alignment(for: column) {
    case .leading:
      return 0
    case .center:
      return max(0, (columnWidth - contentWidth) / 2)
    case .trailing:
      return max(0, columnWidth - contentWidth)
    }
  }

  private func dividerHeight(targetWidth: CGFloat, subviews: Subviews) -> CGFloat {
    guard dividerIndex < subviews.count else { return 0 }
    return subviews[dividerIndex].sizeThatFits(
      ProposedViewSize(width: targetWidth, height: nil)
    ).height
  }

  private func tableRowCount(subviews: Subviews) -> Int {
    max(1, (subviews.count - columnCount - 1) / columnCount + 1)
  }

  private var dividerIndex: Int {
    columnCount
  }

  private func cellIndex(row: Int, column: Int) -> Int? {
    if row == 0 { return column }
    return columnCount + 1 + (row - 1) * columnCount + column
  }

  private func alignment(for column: Int) -> HarnessMarkdownTable.Alignment {
    column < alignments.count ? alignments[column] : .leading
  }
}

private struct HarnessMarkdownTableMeasurement {
  static let empty = Self(
    columnWidths: [],
    rowHeights: [],
    rowY: [],
    dividerY: nil,
    dividerHeight: 0,
    size: .zero
  )

  let columnWidths: [CGFloat]
  let rowHeights: [CGFloat]
  let rowY: [CGFloat]
  let dividerY: CGFloat?
  let dividerHeight: CGFloat
  let size: CGSize
}

private struct HarnessMarkdownTableVerticalPositions {
  static let empty = Self(rowY: [], dividerY: nil, height: 0)

  let rowY: [CGFloat]
  let dividerY: CGFloat?
  let height: CGFloat
}
