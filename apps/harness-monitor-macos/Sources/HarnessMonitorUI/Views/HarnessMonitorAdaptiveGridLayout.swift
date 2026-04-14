import SwiftUI

struct HarnessMonitorAdaptiveGridLayout: Layout {
  struct Cache {
    var measurement: Measurement?
    var measurementKey: MeasurementKey?
  }

  struct Measurement {
    let columns: Int
    let rowHeights: [CGFloat]
    let rowRanges: [Range<Int>]
    let width: CGFloat?
  }

  struct MeasurementKey: Equatable {
    let subviewCount: Int
    let width: CGFloat?

    static func make(subviewCount: Int, width: CGFloat?) -> Self {
      Self(
        subviewCount: subviewCount,
        width: HarnessMonitorAdaptiveGridLayout.normalizedCacheWidth(width)
      )
    }
  }

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

  static func normalizedCacheWidth(_ width: CGFloat?) -> CGFloat? {
    guard let width, width.isFinite, width > 0 else {
      return nil
    }
    return width.rounded(.down)
  }

  static func shouldInvalidateCache(
    cachedSubviewCount: Int?,
    newSubviewCount: Int
  ) -> Bool {
    guard let cachedSubviewCount else {
      return true
    }
    return cachedSubviewCount != newSubviewCount
  }

  func makeCache(subviews _: Subviews) -> Cache {
    Cache()
  }

  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    let cachedSubviewCount = cache.measurementKey?.subviewCount
    guard Self.shouldInvalidateCache(
      cachedSubviewCount: cachedSubviewCount,
      newSubviewCount: subviews.count
    ) else {
      return
    }
    cache = Cache()
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) -> CGSize {
    let measurement = measuredLayout(
      width: proposal.width,
      subviews: subviews,
      cache: &cache
    )
    let rowSpacing = CGFloat(max(measurement.rowHeights.count - 1, 0)) * safeSpacing
    let height = measurement.rowHeights.reduce(0, +) + rowSpacing
    let width =
      proposal.width
      ?? resolvedColumnWidth(width: nil, columns: measurement.columns)
      * CGFloat(measurement.columns)
      + CGFloat(max(measurement.columns - 1, 0)) * safeSpacing

    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) {
    let measurement = measuredLayout(
      width: bounds.width,
      subviews: subviews,
      cache: &cache
    )
    var y = bounds.minY

    for (rowIndex, rowRange) in measurement.rowRanges.enumerated() {
      let rowHeight = measurement.rowHeights[rowIndex]
      let rowColumns = rowRange.count
      let columnWidth = resolvedColumnWidth(width: bounds.width, columns: rowColumns)

      for index in rowRange {
        let columnIndex = index - rowRange.lowerBound
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

  func explicitAlignment(
    of _: HorizontalAlignment,
    in _: CGRect,
    proposal _: ProposedViewSize,
    subviews _: Subviews,
    cache _: inout Cache
  ) -> CGFloat? {
    nil
  }

  func explicitAlignment(
    of _: VerticalAlignment,
    in _: CGRect,
    proposal _: ProposedViewSize,
    subviews _: Subviews,
    cache _: inout Cache
  ) -> CGFloat? {
    nil
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

  private func measuredLayout(
    width: CGFloat?,
    subviews: Subviews,
    cache: inout Cache
  ) -> Measurement {
    let measurementKey = MeasurementKey.make(
      subviewCount: subviews.count,
      width: width
    )
    if cache.measurementKey == measurementKey, let measurement = cache.measurement {
      return measurement
    }

    let columns = resolvedColumnCount(width: width, itemCount: subviews.count)
    let measurement = Measurement(
      columns: columns,
      rowHeights: measuredRowHeights(
        subviews: subviews,
        width: width,
        columns: columns
      ),
      rowRanges: rowRanges(itemCount: subviews.count, columns: columns),
      width: measurementKey.width
    )
    cache.measurementKey = measurementKey
    cache.measurement = measurement
    return measurement
  }

  private func rowRanges(itemCount: Int, columns: Int) -> [Range<Int>] {
    guard itemCount > 0 else {
      return []
    }

    var ranges: [Range<Int>] = []
    var rowStart = 0

    while rowStart < itemCount {
      let rowEnd = min(rowStart + columns, itemCount)
      ranges.append(rowStart..<rowEnd)
      rowStart = rowEnd
    }

    return ranges
  }

  private func measuredRowHeights(
    subviews: Subviews,
    width: CGFloat?,
    columns: Int
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
