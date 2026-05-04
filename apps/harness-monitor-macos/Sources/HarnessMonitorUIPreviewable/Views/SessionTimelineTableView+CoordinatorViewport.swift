import AppKit
import HarnessMonitorKit

extension SessionTimelineTableView.Coordinator {
  func performPendingScrollCommand() -> Bool {
    guard let command = pendingScrollCommand else {
      return false
    }
    if scrollToTarget(command.targetID) {
      pendingScrollCommand = nil
      return true
    }
    return false
  }

  @discardableResult
  func scrollToTarget(_ rowID: String) -> Bool {
    guard
      let tableView,
      let scrollView,
      let index = rowIndexByID[rowID]
    else {
      return false
    }
    tableView.layoutSubtreeIfNeeded()
    let rowRect = tableView.rect(ofRow: index)
    let y = clampedScrollY(rowRect.minY, scrollView: scrollView)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    return true
  }

  func restore(anchor: SessionTimelineTableAnchor?) {
    guard let anchor,
      let tableView,
      let scrollView,
      let index = rowIndexByID[anchor.rowID]
    else {
      return
    }
    let rowRect = tableView.rect(ofRow: index)
    let y = SessionTimelineTableMetrics.restoredScrollY(
      rowMinY: rowRect.minY,
      anchorOffsetY: anchor.offsetY,
      contentHeight: tableView.bounds.height,
      viewportHeight: scrollView.contentSize.height
    )
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  func clampedScrollY(_ y: CGFloat, scrollView: NSScrollView) -> CGFloat {
    guard let tableView else {
      return 0
    }
    return SessionTimelineTableMetrics.clampedScrollY(
      y,
      contentHeight: tableView.bounds.height,
      viewportHeight: scrollView.contentSize.height
    )
  }

  func invalidateVisibleRowHeights() {
    guard let tableView, let scrollView else { return }
    let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
    guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
    let rowRange = visibleRows.location..<(visibleRows.location + visibleRows.length)
    // Evict cached heights for visible rows so heightOfRow falls back to
    // estimate; the background measurement pass will replace them with
    // current-width values.
    for row in rowRange where rows.indices.contains(row) {
      rowHeightCache.removeValue(forKey: rows[row].id)
    }
    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rowRange))
  }

  func currentVisibleAnchor() -> SessionTimelineTableAnchor? {
    guard let tableView, let scrollView else {
      return nil
    }
    let visibleRect = scrollView.contentView.bounds
    guard visibleRect.height > 0, visibleRect.width > 0 else {
      return nil
    }
    let visibleRows = tableView.rows(in: visibleRect)
    guard visibleRows.location != NSNotFound,
      rows.indices.contains(visibleRows.location)
    else {
      return nil
    }
    let rowRect = tableView.rect(ofRow: visibleRows.location)
    return SessionTimelineTableAnchor(
      rowID: rows[visibleRows.location].id,
      offsetY: visibleRect.minY - rowRect.minY
    )
  }

  func publishViewportState() {
    guard let tableView, let scrollView else {
      return
    }
    let visibleRect = scrollView.contentView.bounds
    guard visibleRect.height > 0, visibleRect.width > 0 else {
      return
    }
    let visibleRows = tableView.rows(in: visibleRect)
    let visibleRowCount = max(0, visibleRows.length)
    let stats = SessionTimelineTableViewportStats(
      visibleRowCount: visibleRowCount,
      renderedRowCount: visibleRowCount,
      anchorRowID: anchorRowID(for: visibleRows)
    )
    if lastViewportStats != stats {
      lastViewportStats = stats
      viewport?.recordViewportStats(stats)
    }

    let boundaryState = SessionTimelineScrollBoundaryState(
      visibleMinY: visibleRect.minY,
      visibleMaxY: visibleRect.maxY,
      contentHeight: tableView.bounds.height
    )
    if boundaryState.enteredTopEdge(from: lastBoundaryState)
      || boundaryState.enteredBottomEdge(from: lastBoundaryState)
    {
      let oldValue = lastBoundaryState
      lastBoundaryState = boundaryState
      scrollBoundaryChanged(oldValue, boundaryState)
    } else if boundaryState != lastBoundaryState {
      lastBoundaryState = boundaryState
    }
  }

  func anchorRowID(for visibleRows: NSRange) -> String? {
    guard visibleRows.location != NSNotFound,
      rows.indices.contains(visibleRows.location)
    else {
      return nil
    }
    return rows[visibleRows.location].id
  }
}
