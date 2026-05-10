import AppKit
import CoreGraphics
import HarnessMonitorKit

extension SessionTimelineTableView.Coordinator {
  var tableRowCount: Int { rows.count }

  func dataIndex(forTableRow tableRow: Int) -> Int? {
    guard rows.indices.contains(tableRow) else { return nil }
    return tableRow
  }

  func tableRow(forDataIndex dataIndex: Int) -> Int? {
    guard rows.indices.contains(dataIndex) else { return nil }
    return dataIndex
  }

  func tableRows(forDataIndexes indexes: IndexSet) -> IndexSet {
    var tableRows = IndexSet()
    for index in indexes where rows.indices.contains(index) {
      tableRows.insert(index)
    }
    return tableRows
  }

  func visibleDataRowRange() -> Range<Int>? {
    guard let tableView, let visibleRect = visibleTableRect() else {
      return nil
    }
    return dataRowRange(forTableRows: tableView.rows(in: visibleRect))
  }

  func dataRowRange(forTableRows tableRows: NSRange) -> Range<Int>? {
    guard tableRows.location != NSNotFound, tableRows.length > 0 else {
      return nil
    }
    let lower = max(0, tableRows.location)
    let upper = min(rows.count, lower + tableRows.length)
    return lower < upper ? lower..<upper : nil
  }

  func visibleTableRect() -> NSRect? {
    guard let tableView, let scrollView else {
      return nil
    }
    let visibleDocumentRect = scrollView.contentView.bounds
    guard visibleDocumentRect.height > 0, visibleDocumentRect.width > 0 else {
      return nil
    }
    guard tableDocumentView != nil else {
      return visibleDocumentRect
    }
    let intersection = visibleDocumentRect.intersection(tableView.frame)
    guard !intersection.isNull, intersection.height > 0 else {
      return nil
    }
    return NSRect(
      x: 0,
      y: max(0, intersection.minY - tableView.frame.minY),
      width: intersection.width,
      height: intersection.height
    )
  }

  func virtualY(forTableRowMinY rowMinY: CGFloat) -> CGFloat {
    rowMinY + (tableDocumentView == nil ? 0 : virtualSpacers.topHeight)
  }

  func refreshVirtualLayout(
    rows nextRows: [SessionTimelineRow],
    eventOffsets: [Int?],
    virtualization nextVirtualization: SessionTimelineTableVirtualization,
    columnWidth: CGFloat
  ) {
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
    layoutVirtualDocument(columnWidth: columnWidth, rows: nextRows)
  }

  func recordCurrentKnownEventHeights(columnWidth: CGFloat) {
    recordKnownEventHeights(
      rows: rows,
      eventOffsets: eventOffsetsByRow,
      virtualization: virtualization,
      columnWidth: columnWidth
    )
  }

  func refreshCurrentVirtualLayout(columnWidth: CGFloat) {
    refreshVirtualLayout(
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
    let loadedTop = tableDocumentView == nil ? 0 : virtualSpacers.topHeight
    let loadedHeight = loadedRowsHeight(rows: rows, columnWidth: lastColumnWidth)
    return SessionTimelineScrollBoundaryState(
      visibleMinY: visibleRect.minY - loadedTop,
      visibleMaxY: visibleRect.maxY - loadedTop,
      contentHeight: loadedHeight
    )
  }

  func layoutVirtualDocument(columnWidth: CGFloat, rows nextRows: [SessionTimelineRow]? = nil) {
    guard let scrollView, let tableView else {
      return
    }
    let layoutRows = nextRows ?? rows
    let visibleContentWidth = max(1, scrollView.contentSize.width)
    let width = max(
      1,
      SessionTimelineTableMetrics.resolvedColumnWidth(
        proposedWidth: columnWidth,
        visibleContentWidth: visibleContentWidth,
        horizontalContentInset: horizontalContentInset
      )
    )
    let tableHeight = loadedRowsHeight(rows: layoutRows, columnWidth: width)
    if let documentView = tableDocumentView {
      let documentHeight = max(
        scrollView.contentSize.height,
        virtualSpacers.topHeight + tableHeight + virtualSpacers.bottomHeight
      )
      documentView.setFrameSize(NSSize(width: visibleContentWidth, height: documentHeight))
      tableView.setFrameOrigin(
        NSPoint(x: horizontalContentInset, y: virtualSpacers.topHeight)
      )
      tableView.setFrameSize(NSSize(width: width, height: tableHeight))
    } else {
      tableView.setFrameSize(NSSize(width: width, height: tableHeight))
    }
  }

  private func calculatedVirtualSpacers(
    rows nextRows: [SessionTimelineRow],
    virtualization nextVirtualization: SessionTimelineTableVirtualization,
    columnWidth: CGFloat
  ) -> SessionTimelineTableVirtualSpacers {
    let loadedHeight = loadedRowsHeight(rows: nextRows, columnWidth: columnWidth)
    guard nextVirtualization.isEnabled else {
      return .init(topHeight: 0, bottomHeight: 0, documentHeight: loadedHeight)
    }
    let estimate = virtualRowHeightEstimate(rows: nextRows, loadedHeight: loadedHeight)
    let topHeight = estimatedKnownHeight(
      range: 0..<nextVirtualization.windowStart,
      estimate: estimate
    )
    let minimumDocumentHeight = topHeight + loadedHeight
    let estimatedDocumentHeight = CGFloat(nextVirtualization.totalCount) * estimate
    let previousDocumentHeight = virtualSpacers.documentHeight
    let stableDocumentHeight =
      previousDocumentHeight > 0 && virtualization.totalCount == nextVirtualization.totalCount
      ? max(previousDocumentHeight, minimumDocumentHeight)
      : max(estimatedDocumentHeight, minimumDocumentHeight)
    return .init(
      topHeight: topHeight,
      bottomHeight: max(0, stableDocumentHeight - topHeight - loadedHeight),
      documentHeight: stableDocumentHeight
    )
  }

  private func virtualRowHeightEstimate(
    rows nextRows: [SessionTimelineRow],
    loadedHeight: CGFloat
  ) -> CGFloat {
    let scale = max(1, fontScale)
    let base = SessionTimelineTableMetrics.estimatedBaseRowHeight * scale
    let loadedEventCount = nextRows.reduce(0) { count, row in
      guard case .entry = row.node.identity else {
        return count
      }
      return count + 1
    }
    guard loadedEventCount > 0 else {
      return base
    }
    return max(base, loadedHeight / CGFloat(loadedEventCount))
  }

  private func loadedRowsHeight(
    rows nextRows: [SessionTimelineRow],
    columnWidth: CGFloat
  ) -> CGFloat {
    nextRows.reduce(CGFloat.zero) { total, row in
      total + heightForVirtualization(row: row, columnWidth: columnWidth)
    }
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
    rows sourceRows: [SessionTimelineRow],
    eventOffsets: [Int?],
    virtualization sourceVirtualization: SessionTimelineTableVirtualization,
    columnWidth: CGFloat
  ) {
    guard sourceVirtualization.totalCount > 0 else {
      knownEventHeights.removeAll()
      return
    }
    knownEventHeights = knownEventHeights.filter {
      (0..<sourceVirtualization.totalCount).contains($0.key)
    }
    for (index, row) in sourceRows.enumerated() {
      guard let loadedOffset = eventOffsets.indices.contains(index) ? eventOffsets[index] : nil,
        let cached = rowHeightCache[row.id],
        cached.isMeasured,
        cached.matches(width: columnWidth, tolerance: Self.widthEqualityTolerance)
      else {
        continue
      }
      knownEventHeights[sourceVirtualization.windowStart + loadedOffset] = cached.height
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
}
