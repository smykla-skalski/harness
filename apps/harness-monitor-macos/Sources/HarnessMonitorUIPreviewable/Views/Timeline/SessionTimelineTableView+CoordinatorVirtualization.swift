import AppKit
import CoreGraphics
import HarnessMonitorKit

extension SessionTimelineTableView.Coordinator {
  var tableRowCount: Int {
    rows.count + dataTableRowOffset + (virtualSpacers.hasBottom ? 1 : 0)
  }

  var dataTableRowOffset: Int {
    virtualSpacers.hasTop ? 1 : 0
  }

  func dataIndex(forTableRow tableRow: Int) -> Int? {
    let index = tableRow - dataTableRowOffset
    guard rows.indices.contains(index) else {
      return nil
    }
    return index
  }

  func tableRow(forDataIndex dataIndex: Int) -> Int? {
    guard rows.indices.contains(dataIndex) else {
      return nil
    }
    return dataIndex + dataTableRowOffset
  }

  func virtualSpacerHeight(forTableRow tableRow: Int) -> CGFloat? {
    if virtualSpacers.hasTop, tableRow == 0 {
      return virtualSpacers.topHeight
    }
    if virtualSpacers.hasBottom, tableRow == dataTableRowOffset + rows.count {
      return virtualSpacers.bottomHeight
    }
    return nil
  }

  func makeSpacerCell(in tableView: NSTableView) -> NSView {
    tableView.makeView(
      withIdentifier: SessionTimelineTableSpacerCellView.cellIdentifier,
      owner: self
    ) ?? SessionTimelineTableSpacerCellView()
  }

  func tableRows(forDataIndexes indexes: IndexSet) -> IndexSet {
    var tableRows = IndexSet()
    for index in indexes {
      if let tableRow = tableRow(forDataIndex: index) {
        tableRows.insert(tableRow)
      }
    }
    return tableRows
  }

  func visibleDataRowRange() -> Range<Int>? {
    guard let tableView, let scrollView else {
      return nil
    }
    let bounds = scrollView.contentView.bounds
    guard bounds.height > 0 else {
      return nil
    }
    return dataRowRange(forTableRows: tableView.rows(in: bounds))
  }

  func dataRowRange(forTableRows tableRows: NSRange) -> Range<Int>? {
    guard tableRows.location != NSNotFound, tableRows.length > 0 else {
      return nil
    }
    let lowerTableRow = max(tableRows.location, dataTableRowOffset)
    let upperTableRow = min(
      tableRows.location + tableRows.length,
      dataTableRowOffset + rows.count
    )
    guard lowerTableRow < upperTableRow else {
      return nil
    }
    return (lowerTableRow - dataTableRowOffset)..<(upperTableRow - dataTableRowOffset)
  }

  func refreshVirtualSpacers(
    rows nextRows: [SessionTimelineRow],
    eventOffsets: [Int?],
    virtualization nextVirtualization: SessionTimelineTableVirtualization,
    columnWidth: CGFloat
  ) -> IndexSet {
    let previousSpacers = virtualSpacers
    recordKnownEventHeights(
      rows: nextRows,
      eventOffsets: eventOffsets,
      virtualization: nextVirtualization,
      columnWidth: columnWidth
    )
    virtualization = nextVirtualization
    virtualSpacers = calculatedVirtualSpacers(
      rows: nextRows,
      virtualization: nextVirtualization,
      columnWidth: columnWidth
    )
    guard previousSpacers != virtualSpacers else {
      return []
    }
    return changedSpacerRows(previous: previousSpacers, next: virtualSpacers)
  }

  func refreshCurrentVirtualSpacers(columnWidth: CGFloat) -> IndexSet {
    refreshVirtualSpacers(
      rows: rows,
      eventOffsets: eventOffsetsByRow,
      virtualization: virtualization,
      columnWidth: columnWidth
    )
  }

  func loadedBoundaryState() -> SessionTimelineScrollBoundaryState? {
    guard let scrollView else {
      return nil
    }
    let visibleRect = scrollView.contentView.bounds
    guard visibleRect.height > 0, visibleRect.width > 0 else {
      return nil
    }
    let relativeVisibleMinY = visibleRect.minY - virtualSpacers.topHeight
    let relativeVisibleMaxY = visibleRect.maxY - virtualSpacers.topHeight
    return SessionTimelineScrollBoundaryState(
      visibleMinY: relativeVisibleMinY,
      visibleMaxY: relativeVisibleMaxY,
      contentHeight: loadedRowsHeight()
    )
  }

  private func calculatedVirtualSpacers(
    rows nextRows: [SessionTimelineRow],
    virtualization nextVirtualization: SessionTimelineTableVirtualization,
    columnWidth: CGFloat
  ) -> SessionTimelineTableVirtualSpacers {
    guard nextVirtualization.isEnabled else {
      return .zero
    }
    let estimate = nextVirtualization.virtualRowHeight * max(1, fontScale)
    let targetHeight = CGFloat(nextVirtualization.totalCount) * estimate
    let topHeight = estimatedKnownHeight(
      range: 0..<nextVirtualization.windowStart,
      estimate: estimate
    )
    let loadedHeight = nextRows.reduce(CGFloat.zero) { total, row in
      total + heightForVirtualization(row: row, columnWidth: columnWidth)
    }
    let bottomHeight = max(0, targetHeight - topHeight - loadedHeight)
    return SessionTimelineTableVirtualSpacers(
      topHeight: topHeight,
      bottomHeight: bottomHeight
    )
  }

  private func heightForVirtualization(
    row: SessionTimelineRow,
    columnWidth: CGFloat
  ) -> CGFloat {
    if let cached = rowHeightCache[row.id],
      cached.matches(width: columnWidth, tolerance: Self.widthEqualityTolerance)
    {
      return cached.height
    }
    return SessionTimelineTableMetrics.estimatedHeight(for: row, fontScale: fontScale)
  }

  private func recordKnownEventHeights(
    rows nextRows: [SessionTimelineRow],
    eventOffsets: [Int?],
    virtualization nextVirtualization: SessionTimelineTableVirtualization,
    columnWidth: CGFloat
  ) {
    guard nextVirtualization.isEnabled else {
      knownEventHeights.removeAll()
      return
    }
    knownEventHeights = knownEventHeights.filter {
      (0..<nextVirtualization.totalCount).contains($0.key)
    }
    for (index, row) in nextRows.enumerated() {
      guard let loadedOffset = eventOffsets.indices.contains(index) ? eventOffsets[index] : nil,
        let cached = rowHeightCache[row.id],
        cached.isMeasured,
        cached.matches(width: columnWidth, tolerance: Self.widthEqualityTolerance)
      else {
        continue
      }
      knownEventHeights[nextVirtualization.windowStart + loadedOffset] = cached.height
    }
  }

  private func estimatedKnownHeight(range: Range<Int>, estimate: CGFloat) -> CGFloat {
    guard !range.isEmpty else {
      return 0
    }
    var height = CGFloat(range.count) * estimate
    for (offset, knownHeight) in knownEventHeights where range.contains(offset) {
      height += knownHeight - estimate
    }
    return max(0, height)
  }

  private func changedSpacerRows(
    previous: SessionTimelineTableVirtualSpacers,
    next: SessionTimelineTableVirtualSpacers
  ) -> IndexSet {
    var indexes = IndexSet()
    if previous.hasTop || next.hasTop {
      indexes.insert(0)
    }
    if previous.hasBottom || next.hasBottom {
      indexes.insert(dataTableRowOffset + rows.count)
    }
    return indexes
  }

  private func loadedRowsHeight() -> CGFloat {
    rows.reduce(CGFloat.zero) { total, row in
      total + heightForVirtualization(row: row, columnWidth: lastColumnWidth)
    }
  }
}
