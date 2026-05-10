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
    boundsDidChange(forceObservedStats: true)
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
    syncBoundaryStateToCurrentViewport()
    boundsDidChange(forceObservedStats: true)
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

  func isPinnedToLatestViewport() -> Bool {
    guard let tableView, let scrollView else {
      return false
    }
    let visibleRect = scrollView.contentView.bounds
    guard visibleRect.height > 0, visibleRect.width > 0 else {
      return false
    }
    let visibleRows = tableView.rows(in: visibleRect)
    let firstVisibleRowIndex = visibleRows.location == NSNotFound ? nil : visibleRows.location
    return SessionTimelineTableMetrics.shouldStickToLatestOnRowsChange(
      visibleMinY: visibleRect.minY,
      firstVisibleRowIndex: firstVisibleRowIndex
    )
  }

  @discardableResult
  func normalizePinnedLatestViewportIfNeeded() -> Bool {
    guard
      let scrollView,
      let tableView
    else {
      return false
    }
    let visibleMinY = scrollView.contentView.bounds.minY
    let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
    guard
      SessionTimelineTableMetrics.shouldNormalizeLatestViewport(
        visibleMinY: visibleMinY,
        firstVisibleRowIndex: visibleRows.location == NSNotFound ? nil : visibleRows.location
      )
    else {
      return false
    }
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    syncBoundaryStateToCurrentViewport()
    return true
  }

  func currentBoundaryState() -> SessionTimelineScrollBoundaryState? {
    guard let tableView, let scrollView else {
      return nil
    }
    let visibleRect = scrollView.contentView.bounds
    guard visibleRect.height > 0, visibleRect.width > 0 else {
      return nil
    }
    return SessionTimelineScrollBoundaryState(
      visibleMinY: visibleRect.minY,
      visibleMaxY: visibleRect.maxY,
      contentHeight: tableView.bounds.height
    )
  }

  func syncBoundaryStateToCurrentViewport() {
    guard let boundaryState = currentBoundaryState() else {
      return
    }
    lastBoundaryState = boundaryState
    viewport?.recordScrollBoundaryState(boundaryState)
  }

  func boundsDidChange() {
    boundsDidChange(forceObservedStats: false)
  }

  func boundsDidChange(forceObservedStats: Bool) {
    refreshColumnWidthFromScrollViewIfNeeded()
    pendingPublishForcesObservedStats = pendingPublishForcesObservedStats || forceObservedStats
    guard !pendingPublish else { return }
    pendingPublish = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      let shouldForceObservedStats = self.pendingPublishForcesObservedStats
      self.pendingPublish = false
      self.pendingPublishForcesObservedStats = false
      self.publishViewportState(forceObservedStats: shouldForceObservedStats)
    }
  }

  func publishViewportState(forceObservedStats: Bool = false) {
    guard let tableView, let scrollView else {
      return
    }
    let visibleRect = scrollView.contentView.bounds
    guard visibleRect.height > 0, visibleRect.width > 0 else {
      return
    }
    let visibleRows = tableView.rows(in: visibleRect)
    let visibleRowCount = max(0, visibleRows.length)
    let viewportRowCapacity = max(
      visibleRowCount,
      Int(ceil(visibleRect.height / SessionTimelineSectionPresentation.rowHeightEstimate))
    )
    let visibleEventOffsets = visibleEventOffsets(for: visibleRows)
    let visibleMatchOffsets = visibleMatchOffsets(for: visibleRows)
    let stats = SessionTimelineTableViewportStats(
      visibleRowCount: visibleRowCount,
      renderedRowCount: visibleRowCount,
      viewportRowCapacity: viewportRowCapacity,
      anchorRowID: anchorRowID(for: visibleRows),
      firstVisibleEventOffset: visibleEventOffsets?.lowerBound,
      lastVisibleEventOffset: visibleEventOffsets?.upperBound,
      firstVisibleMatchOffset: visibleMatchOffsets?.lowerBound,
      lastVisibleMatchOffset: visibleMatchOffsets?.upperBound
    )
    let previousStats = lastViewportStats
    if previousStats != stats {
      lastViewportStats = stats
      viewport?.recordViewportStats(stats, publishImmediately: forceObservedStats)
      if previousStats?.viewportRowCapacity != stats.viewportRowCapacity {
        viewportChanged(stats)
      }
    }
    if measurementTask == nil, visibleRowsNeedMeasurement(columnWidth: lastColumnWidth) {
      scheduleIncrementalMeasurement(columnWidth: lastColumnWidth)
    }

    guard let boundaryState = currentBoundaryState() else {
      return
    }
    viewport?.recordScrollBoundaryState(boundaryState)
    if boundaryState.enteredTopEdge(from: lastBoundaryState)
      || boundaryState.enteredBottomEdge(from: lastBoundaryState)
    {
      let oldValue = lastBoundaryState
      lastBoundaryState = boundaryState
      scrollBoundaryChanged(oldValue, boundaryState)
    } else if boundaryState.shouldTrack(from: lastBoundaryState) {
      lastBoundaryState = boundaryState
    }
  }

  func resizeColumn(in scrollView: NSScrollView, columnWidth: CGFloat) {
    guard let tableView, let column = tableView.tableColumns.first else { return }
    guard columnWidth > 1 else { return }
    let isFirstRealWidth = lastColumnWidth <= 1
    let widthChanged =
      !isFirstRealWidth && abs(columnWidth - lastColumnWidth) > Self.widthEqualityTolerance
    if column.width != columnWidth {
      column.width = columnWidth
    }
    guard isFirstRealWidth || widthChanged else { return }
    lastColumnWidth = columnWidth
    cancelMeasurement(reason: widthChanged ? "width_changed" : "first_real_width")
    performWithoutTableAnimation {
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<rows.count))
    }
    scheduleIncrementalMeasurement(columnWidth: columnWidth)
  }

  func resolvedColumnWidth(for request: SessionTimelineTableView.UpdateRequest) -> CGFloat {
    if lastColumnWidth <= 1 {
      request.scrollView.layoutSubtreeIfNeeded()
    }
    return SessionTimelineTableMetrics.resolvedColumnWidth(
      proposedWidth: request.columnWidth,
      visibleContentWidth: request.scrollView.contentSize.width
    )
  }

  func applyWidthOnlyUpdateIfNeeded(columnWidth: CGFloat) {
    guard columnWidth > 1, let tableView, let column = tableView.tableColumns.first else {
      return
    }
    guard abs(columnWidth - lastColumnWidth) >= Self.widthEqualityTolerance else {
      return
    }
    if column.width != columnWidth {
      column.width = columnWidth
    }
    lastColumnWidth = columnWidth
    scheduleIncrementalMeasurement(
      columnWidth: columnWidth,
      debounceNanoseconds: Self.widthAnimationMeasurementDebounceNs
    )
  }

  @discardableResult
  func refreshColumnWidthFromScrollViewIfNeeded() -> Bool {
    guard let scrollView else {
      return false
    }
    let columnWidth = SessionTimelineTableMetrics.resolvedColumnWidth(
      proposedWidth: 0,
      visibleContentWidth: scrollView.contentSize.width
    )
    let previousWidth = lastColumnWidth
    applyWidthOnlyUpdateIfNeeded(columnWidth: columnWidth)
    return abs(columnWidth - previousWidth) >= Self.widthEqualityTolerance
  }

  func anchorRowID(for visibleRows: NSRange) -> String? {
    guard visibleRows.location != NSNotFound,
      rows.indices.contains(visibleRows.location)
    else {
      return nil
    }
    return rows[visibleRows.location].id
  }

  func eventOffsets(for rows: [SessionTimelineRow]) -> [Int?] {
    var nextOffset = 0
    return rows.map { row in
      guard case .entry = row.node.identity else {
        return nil
      }
      defer { nextOffset += 1 }
      return nextOffset
    }
  }

  func visibleEventOffsets(for visibleRows: NSRange) -> ClosedRange<Int>? {
    guard visibleRows.location != NSNotFound, visibleRows.length > 0 else {
      return nil
    }
    let upperBound = min(visibleRows.location + visibleRows.length, eventOffsetsByRow.count)
    guard visibleRows.location < upperBound else {
      return nil
    }
    var firstVisibleEventOffset: Int?
    var lastVisibleEventOffset: Int?
    for rowIndex in visibleRows.location..<upperBound {
      guard let eventOffset = eventOffsetsByRow[rowIndex] else {
        continue
      }
      firstVisibleEventOffset = firstVisibleEventOffset ?? eventOffset
      lastVisibleEventOffset = eventOffset
    }
    guard let firstVisibleEventOffset, let lastVisibleEventOffset else {
      return nil
    }
    return firstVisibleEventOffset...lastVisibleEventOffset
  }

  func visibleMatchOffsets(for visibleRows: NSRange) -> ClosedRange<Int>? {
    guard visibleRows.location != NSNotFound, visibleRows.length > 0 else {
      return nil
    }
    let upperBound = visibleRows.location + visibleRows.length
    guard visibleRows.location < upperBound else {
      return nil
    }
    return visibleRows.location...(upperBound - 1)
  }
}
