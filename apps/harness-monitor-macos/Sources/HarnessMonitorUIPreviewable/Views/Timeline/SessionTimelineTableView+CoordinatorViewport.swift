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
      let index = rowIndexByID[rowID],
      let tableRow = tableRow(forDataIndex: index)
    else {
      return false
    }
    tableView.layoutSubtreeIfNeeded()
    let rowRect = tableView.rect(ofRow: tableRow)
    restoreScrollY(virtualY(forTableRowMinY: rowRect.minY), forceObservedStats: true)
    return true
  }

  func restore(anchor: SessionTimelineTableAnchor?) {
    guard let anchor,
      let tableView,
      let scrollView,
      let index = rowIndexByID[anchor.rowID],
      let tableRow = tableRow(forDataIndex: index)
    else {
      return
    }
    let rowRect = tableView.rect(ofRow: tableRow)
    let y = SessionTimelineTableMetrics.restoredScrollY(
      rowMinY: virtualY(forTableRowMinY: rowRect.minY),
      anchorOffsetY: anchor.offsetY,
      contentHeight: virtualContentHeight(),
      viewportHeight: scrollView.contentSize.height
    )
    restoreScrollY(y, forceObservedStats: true, suppressBoundaryCallbacks: true)
  }

  func currentScrollY() -> CGFloat? {
    scrollView?.contentView.bounds.minY
  }

  func restoreScrollY(
    _ y: CGFloat,
    forceObservedStats: Bool = true,
    suppressBoundaryCallbacks: Bool = false
  ) {
    guard let scrollView else {
      return
    }
    let resolvedY = clampedScrollY(y, scrollView: scrollView)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: resolvedY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    syncBoundaryStateToCurrentViewport()
    boundsDidChange(
      forceObservedStats: forceObservedStats,
      suppressBoundaryCallbacks: suppressBoundaryCallbacks
    )
  }

  func clampedScrollY(_ y: CGFloat, scrollView: NSScrollView) -> CGFloat {
    return SessionTimelineTableMetrics.clampedScrollY(
      y,
      contentHeight: virtualContentHeight(),
      viewportHeight: scrollView.contentSize.height
    )
  }

  func virtualContentHeight() -> CGFloat {
    if let documentView = tableDocumentView {
      return max(documentView.bounds.height, virtualSpacers.documentHeight)
    }
    return tableView?.bounds.height ?? 0
  }

  func currentVisibleAnchor() -> SessionTimelineTableAnchor? {
    guard let tableView, let scrollView else {
      return nil
    }
    let visibleRect = scrollView.contentView.bounds
    guard visibleRect.height > 0, visibleRect.width > 0 else {
      return nil
    }
    guard
      let visibleRange = visibleDataRowRange(),
      let dataIndex = visibleRange.first,
      let tableRow = tableRow(forDataIndex: dataIndex)
    else {
      return nil
    }
    let rowRect = tableView.rect(ofRow: tableRow)
    return SessionTimelineTableAnchor(
      rowID: rows[dataIndex].id,
      offsetY: visibleRect.minY - virtualY(forTableRowMinY: rowRect.minY)
    )
  }

  func isPinnedToLatestViewport() -> Bool {
    guard let scrollView else {
      return false
    }
    let visibleRect = scrollView.contentView.bounds
    guard visibleRect.height > 0, visibleRect.width > 0 else {
      return false
    }
    guard
      virtualSpacers.topHeight <= Self.widthEqualityTolerance,
      let visibleRange = visibleDataRowRange(),
      let dataIndex = visibleRange.first
    else {
      return false
    }
    return SessionTimelineTableMetrics.shouldStickToLatestOnRowsChange(
      visibleMinY: visibleRect.minY,
      firstVisibleRowIndex: dataIndex
    )
  }

  @discardableResult
  func normalizePinnedLatestViewportIfNeeded() -> Bool {
    guard let scrollView else {
      return false
    }
    let visibleMinY = scrollView.contentView.bounds.minY
    let visibleRows = visibleDataRowRange()
    guard
      SessionTimelineTableMetrics.shouldNormalizeLatestViewport(
        visibleMinY: visibleMinY,
        firstVisibleRowIndex: visibleRows?.lowerBound
      )
    else {
      return false
    }
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    syncBoundaryStateToCurrentViewport()
    boundsDidChange(forceObservedStats: true, suppressBoundaryCallbacks: true)
    return true
  }

  func currentBoundaryState() -> SessionTimelineScrollBoundaryState? {
    guard let scrollView else {
      return nil
    }
    let visibleRect = scrollView.contentView.bounds
    guard visibleRect.height > 0, visibleRect.width > 0 else {
      return nil
    }
    return loadedBoundaryState()
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

  func boundsDidChange(
    forceObservedStats: Bool,
    suppressBoundaryCallbacks: Bool = false
  ) {
    refreshColumnWidthFromScrollViewIfNeeded()
    pendingPublishForcesObservedStats = pendingPublishForcesObservedStats || forceObservedStats
    pendingPublishSuppressesBoundaryCallbacks =
      pendingPublishSuppressesBoundaryCallbacks || suppressBoundaryCallbacks
    guard !pendingPublish else { return }
    pendingPublish = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      let shouldForceObservedStats = self.pendingPublishForcesObservedStats
      let shouldSuppressBoundaryCallbacks = self.pendingPublishSuppressesBoundaryCallbacks
      self.pendingPublish = false
      self.pendingPublishForcesObservedStats = false
      self.pendingPublishSuppressesBoundaryCallbacks = false
      self.publishViewportState(
        forceObservedStats: shouldForceObservedStats,
        suppressBoundaryCallbacks: shouldSuppressBoundaryCallbacks
      )
    }
  }

  func publishViewportState(
    forceObservedStats: Bool = false,
    suppressBoundaryCallbacks: Bool = false
  ) {
    guard let scrollView else {
      return
    }
    if eventOffsetsByRow.count != rows.count {
      eventOffsetsByRow = eventOffsets(for: rows)
    }
    let visibleRect = scrollView.contentView.bounds
    guard visibleRect.height > 0, visibleRect.width > 0 else {
      return
    }
    let visibleRows = visibleDataRowRange()
    let visibleRowCount = visibleRows?.count ?? 0
    let viewportRowCapacity = max(
      visibleRowCount,
      Int(ceil(visibleRect.height / SessionTimelineSectionPresentation.rowHeightEstimate))
    )
    let visibleRowRange = visibleRows.map {
      NSRange(location: $0.lowerBound, length: $0.count)
    } ?? NSRange(location: NSNotFound, length: 0)
    let visibleEventOffsets = visibleEventOffsets(for: visibleRowRange)
    let visibleMatchOffsets = visibleMatchOffsets(for: visibleRowRange)
    let stats = SessionTimelineTableViewportStats(
      visibleRowCount: visibleRowCount,
      renderedRowCount: visibleRowCount,
      viewportRowCapacity: viewportRowCapacity,
      anchorRowID: anchorRowID(for: visibleRowRange),
      firstVisibleEventOffset: visibleEventOffsets?.lowerBound,
      lastVisibleEventOffset: visibleEventOffsets?.upperBound,
      firstVisibleMatchOffset: visibleMatchOffsets?.lowerBound,
      lastVisibleMatchOffset: visibleMatchOffsets?.upperBound
    )
    let previousStats = lastViewportStats
    if previousStats != stats {
      lastViewportStats = stats
      viewport?.recordViewportStats(
        stats,
        publishImmediately: forceObservedStats || previousStats == nil
      )
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
    if suppressBoundaryCallbacks {
      lastBoundaryState = boundaryState
      return
    }
    let enteredTopEdge = boundaryState.enteredTopEdge(from: lastBoundaryState)
    let enteredBottomEdge = boundaryState.enteredBottomEdge(from: lastBoundaryState)
    if enteredTopEdge || enteredBottomEdge {
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
    let invalidationIndexes = visibleMeasurementInvalidationIndexes()
    if !invalidationIndexes.isEmpty {
      performWithoutTableAnimation {
        tableView.noteHeightOfRows(withIndexesChanged: tableRows(forDataIndexes: invalidationIndexes))
      }
    }
    refreshCurrentVirtualLayout(columnWidth: columnWidth)
    scheduleIncrementalMeasurement(columnWidth: columnWidth)
  }

  func resolvedColumnWidth(for request: SessionTimelineTableView.UpdateRequest) -> CGFloat {
    if lastColumnWidth <= 1 {
      request.scrollView.layoutSubtreeIfNeeded()
    }
    return SessionTimelineTableMetrics.resolvedColumnWidth(
      proposedWidth: request.columnWidth,
      visibleContentWidth: request.scrollView.contentSize.width,
      horizontalContentInset: request.horizontalContentInset
    )
  }

  func applyWidthOnlyUpdateIfNeeded(
    columnWidth: CGFloat,
    horizontalContentInset: CGFloat
  ) {
    guard columnWidth > 1, let tableView, let column = tableView.tableColumns.first else {
      return
    }
    let widthChanged = abs(columnWidth - lastColumnWidth) >= Self.widthEqualityTolerance
    let insetChanged = abs(horizontalContentInset - self.horizontalContentInset)
      >= Self.widthEqualityTolerance
    guard widthChanged || insetChanged else {
      return
    }
    cancelMeasurement(reason: widthChanged ? "width_changed" : "content_inset_changed")
    if column.width != columnWidth {
      column.width = columnWidth
    }
    lastColumnWidth = columnWidth
    self.horizontalContentInset = horizontalContentInset
    refreshCurrentVirtualLayout(columnWidth: columnWidth)
    if widthChanged {
      scheduleIncrementalMeasurement(
        columnWidth: columnWidth,
        debounceNanoseconds: Self.widthAnimationMeasurementDebounceNs
      )
    }
  }

  private func visibleMeasurementInvalidationIndexes() -> IndexSet {
    guard !rows.isEmpty else {
      return []
    }
    let visibleRange =
      visibleMeasurementRange() ?? 0..<min(rows.count, Self.measurementPrefetchRowCount)
    let lowerBound = max(0, visibleRange.lowerBound - Self.measurementPrefetchRowCount)
    let upperBound = min(rows.count, visibleRange.upperBound + Self.measurementPrefetchRowCount)
    guard lowerBound < upperBound else {
      return []
    }
    return IndexSet(integersIn: lowerBound..<upperBound)
  }

  private func visibleMeasurementRange() -> Range<Int>? {
    visibleDataRowRange()
  }

  @discardableResult
  func refreshColumnWidthFromScrollViewIfNeeded() -> Bool {
    guard let scrollView else {
      return false
    }
    let columnWidth = SessionTimelineTableMetrics.resolvedColumnWidth(
      proposedWidth: 0,
      visibleContentWidth: scrollView.contentSize.width,
      horizontalContentInset: horizontalContentInset
    )
    let previousWidth = lastColumnWidth
    applyWidthOnlyUpdateIfNeeded(
      columnWidth: columnWidth,
      horizontalContentInset: horizontalContentInset
    )
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
