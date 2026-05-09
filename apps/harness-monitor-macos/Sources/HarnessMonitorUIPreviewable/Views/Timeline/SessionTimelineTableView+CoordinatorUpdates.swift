import AppKit
import Combine
import HarnessMonitorKit
import OSLog
import SwiftUI

extension SessionTimelineTableView.Coordinator {
  func update(
    rows: [SessionTimelineRow],
    contentIdentity: SessionTimelineContentIdentity? = nil,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)?,
    scrollCommand: SessionTimelineScrollCommand?,
    request: SessionTimelineTableView.UpdateRequest
  ) {
    guard let tableView else {
      return
    }
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap

    // Cheap fingerprint identifies "same rows" in O(1). When the parent body
    // re-renders during the sidebar reveal animation the rows array is
    // structurally unchanged, so a count + endpoints check reliably matches
    // and lets us skip the per-frame snapshot allocation (~17 strings × N
    // rows) and the Set<String> diff that dominate the time profile.
    let rowsLookSame =
      rows.count == self.rows.count && rows.first?.id == self.rows.first?.id
      && rows.last?.id == self.rows.last?.id
    let widthDelta = abs(request.columnWidth - lastColumnWidth)
    let widthSame = widthDelta < Self.widthEqualityTolerance
    let fontSame = abs(request.fontScale - fontScale) < 0.001
    let scrollSame = scrollCommand == lastScrollCommand && pendingScrollCommand == nil
    let identitySame = contentIdentity == heightCacheIdentity

    if rowsLookSame, widthSame, fontSame, scrollSame, identitySame {
      return
    }

    // Width-only path: during animation the only thing that changes per frame
    // is the proposed column width. Apply it smoothly to the AppKit column
    // and reschedule the measurement task (which auto-debounces by cancelling
    // its predecessor) without invalidating heights via noteHeightOfRows. The
    // per-tick noteHeightOfRows call was the source of the reveal stall.
    if rowsLookSame, fontSame, scrollSame, identitySame {
      if request.columnWidth > 1, let column = tableView.tableColumns.first {
        if column.width != request.columnWidth {
          column.width = request.columnWidth
        }
        lastColumnWidth = request.columnWidth
        scheduleIncrementalMeasurement(columnWidth: request.columnWidth)
      }
      return
    }

    request.scrollView.layoutSubtreeIfNeeded()
    let resolvedColumnWidth = SessionTimelineTableMetrics.resolvedColumnWidth(
      proposedWidth: request.columnWidth,
      visibleContentWidth: request.scrollView.contentSize.width
    )
    let previousFontScale = fontScale
    let wasPinnedToLatest = isPinnedToLatestViewport()
    let previousAnchor = wasPinnedToLatest ? nil : currentVisibleAnchor()
    let nextSnapshot = SessionTimelineTableSnapshot(rows: rows)
    let restoredHeightCache = restoreHeightCacheIfNeeded(
      identity: contentIdentity,
      snapshot: nextSnapshot,
      fontScale: request.fontScale
    )
    let fontScaleChanged =
      !restoredHeightCache && abs(previousFontScale - request.fontScale) > 0.001
    fontScale = request.fontScale
    let invalidatedHeightIDs = nextSnapshot.heightCacheInvalidationIDs(
      comparedTo: rowSnapshot,
      fontScaleChanged: fontScaleChanged
    )
    let rowsChanged = rowSnapshot != nextSnapshot || fontScaleChanged
    if rowsChanged {
      applyRowChanges(
        rows: rows,
        nextSnapshot: nextSnapshot,
        invalidatedHeightIDs: invalidatedHeightIDs,
        resolvedColumnWidth: resolvedColumnWidth,
        fontScaleChanged: fontScaleChanged
      )
    }
    resizeColumn(in: request.scrollView, columnWidth: resolvedColumnWidth)

    if scrollCommand != lastScrollCommand {
      pendingScrollCommand = scrollCommand
      lastScrollCommand = scrollCommand
    }
    let didPerformScrollCommand = performPendingScrollCommand()
    let hasUnfulfilledScrollCommand = pendingScrollCommand != nil
    if !didPerformScrollCommand && rowsChanged {
      restoreViewportAfterRowChange(
        hasUnfulfilledScrollCommand: hasUnfulfilledScrollCommand,
        wasPinnedToLatest: wasPinnedToLatest,
        previousAnchor: previousAnchor
      )
    }
  }

  private func applyRowChanges(
    rows: [SessionTimelineRow],
    nextSnapshot: SessionTimelineTableSnapshot,
    invalidatedHeightIDs: Set<String>,
    resolvedColumnWidth: CGFloat,
    fontScaleChanged: Bool
  ) {
    guard let tableView else {
      return
    }
    let nextIDs = Set(rows.map(\.id))
    let priorIDs = Set(self.rows.map(\.id))
    let willReuseAny = !fontScaleChanged && !nextIDs.isDisjoint(with: priorIDs)
    let updateInterval = beginRowChangeInterval(
      rowCount: rows.count,
      willReuseAny: willReuseAny,
      resolvedColumnWidth: resolvedColumnWidth
    )
    defer {
      Self.signposter.endInterval("session_timeline.update_rows_changed", updateInterval)
    }

    cancelMeasurement(reason: "rows_changed")
    reuseVisibleHeightsIfNeeded(
      willReuseAny: willReuseAny,
      nextIDs: nextIDs,
      invalidatedHeightIDs: invalidatedHeightIDs,
      tableView: tableView
    )
    rowHeightCache = rowHeightCache.filter {
      nextIDs.contains($0.key) && !invalidatedHeightIDs.contains($0.key)
    }

    self.rows = rows
    eventOffsetsByRow = eventOffsets(for: rows)
    rowIndexByID = Dictionary(
      uniqueKeysWithValues: rows.enumerated().map { index, row in
        (row.id, index)
      }
    )
    rowSnapshot = nextSnapshot
    tableView.reloadData()
    tableView.layoutSubtreeIfNeeded()
    persistHeightCache()

    if resolvedColumnWidth > 1 {
      scheduleIncrementalMeasurement(columnWidth: resolvedColumnWidth)
    }
  }

  private func beginRowChangeInterval(
    rowCount: Int,
    willReuseAny: Bool,
    resolvedColumnWidth: CGFloat
  ) -> OSSignpostIntervalState {
    let colWidth = Int(resolvedColumnWidth)
    return Self.signposter.beginInterval(
      "session_timeline.update_rows_changed",
      id: Self.signposter.makeSignpostID(),
      "n=\(rowCount, privacy: .public) r=\(willReuseAny, privacy: .public) w=\(colWidth, privacy: .public)"
    )
  }

  func restoreHeightCacheIfNeeded(
    identity: SessionTimelineContentIdentity?,
    snapshot: SessionTimelineTableSnapshot,
    fontScale: CGFloat
  ) -> Bool {
    if heightCacheIdentity != identity {
      persistHeightCache()
      heightCacheIdentity = identity
      rowHeightCache = [:]
      rowSnapshot = .empty
    }
    guard
      let seed = SessionTimelineTableHeightCacheStore.restore(
        identity: identity,
        snapshot: snapshot,
        fontScale: fontScale
      )
    else {
      return false
    }
    var didRestoreHeight = false
    for (id, height) in seed.heightsByID where rowHeightCache[id] == nil {
      rowHeightCache[id] = height
      didRestoreHeight = true
    }
    return didRestoreHeight
  }

  func persistHeightCache() {
    SessionTimelineTableHeightCacheStore.save(
      identity: heightCacheIdentity,
      snapshot: rowSnapshot,
      heightsByID: rowHeightCache,
      fontScale: fontScale
    )
  }

  private func reuseVisibleHeightsIfNeeded(
    willReuseAny: Bool,
    nextIDs: Set<String>,
    invalidatedHeightIDs: Set<String>,
    tableView: NSTableView
  ) {
    guard willReuseAny, let visibleRange = visibleRowIndexRange() else {
      return
    }
    for rowIndex in visibleRange {
      guard self.rows.indices.contains(rowIndex) else { continue }
      let rowID = self.rows[rowIndex].id
      guard nextIDs.contains(rowID), !invalidatedHeightIDs.contains(rowID) else {
        continue
      }
      guard let cached = rowHeightCache[rowID] else {
        continue
      }
      guard cached.isMeasured else {
        rowHeightCache.removeValue(forKey: rowID)
        continue
      }
      rowHeightCache[rowID] = CachedRowHeight(
        width: lastColumnWidth,
        height: tableView.rect(ofRow: rowIndex).height,
        isMeasured: true
      )
    }
  }

  private func restoreViewportAfterRowChange(
    hasUnfulfilledScrollCommand: Bool,
    wasPinnedToLatest: Bool,
    previousAnchor: SessionTimelineTableAnchor?
  ) {
    if !hasUnfulfilledScrollCommand && normalizePinnedLatestViewportIfNeeded() {
      boundsDidChange()
      return
    }
    if wasPinnedToLatest && !hasUnfulfilledScrollCommand {
      boundsDidChange()
      return
    }
    restore(anchor: previousAnchor)
  }

  func numberOfRows(in _: NSTableView) -> Int {
    rows.count
  }

  func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard rows.indices.contains(row) else {
      return SessionTimelineTableMetrics.estimatedBaseRowHeight
    }
    let rowData = rows[row]
    if let cached = rowHeightCache[rowData.id],
      cached.matches(width: lastColumnWidth, tolerance: Self.widthEqualityTolerance)
    {
      return cached.height
    }
    return SessionTimelineTableMetrics.estimatedHeight(for: rowData, fontScale: fontScale)
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor _: NSTableColumn?,
    row: Int
  ) -> NSView? {
    guard rows.indices.contains(row) else {
      return nil
    }
    let cell =
      tableView.makeView(
        withIdentifier: SessionTimelineTableCellView.cellIdentifier,
        owner: self
      ) as? SessionTimelineTableCellView
      ?? SessionTimelineTableCellView()
    let connectorVisibility = SessionTimelineTableMetrics.connectorVisibility(
      rowIndex: row,
      rowCount: rows.count
    )
    cell.update(
      row: rows[row],
      actionHandler: actionHandler,
      onSignalTap: onSignalTap,
      fontScale: fontScale,
      connectorVisibility: connectorVisibility
    )
    return cell
  }

  func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
    SessionTimelineTableRowView()
  }

  func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
    false
  }

  func boundsDidChange() {
    guard !pendingPublish else { return }
    pendingPublish = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.pendingPublish = false
      self.publishViewportState()
    }
  }

  private func resizeColumn(in scrollView: NSScrollView, columnWidth: CGFloat) {
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
    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<rows.count))
    scheduleIncrementalMeasurement(columnWidth: columnWidth)
  }

  func scheduleIncrementalMeasurement(columnWidth: CGFloat) {
    guard columnWidth > 1, !rows.isEmpty else {
      return
    }
    let snapshot = rows
    let visibleRange = visibleRowIndexRange()
    let measurementOrder = Self.orderedMeasurementIndexes(
      rowCount: snapshot.count,
      visibleRange: visibleRange,
      mode: SessionTimelineTableMeasurementMode.current
    )
    let outstanding = measurementOrder.filter { index in
      guard snapshot.indices.contains(index) else { return false }
      let id = snapshot[index].id
      guard let cached = rowHeightCache[id] else { return true }
      return cached.requiresMeasurement(for: columnWidth, tolerance: Self.widthEqualityTolerance)
    }
    guard !outstanding.isEmpty else {
      return
    }
    cancelMeasurement(reason: "reschedule")
    self.measurementGeneration &+= 1
    let generation = self.measurementGeneration
    let totalOutstanding = outstanding.count
    let cw = Int(columnWidth)
    Self.signposter.emitEvent(
      "session_timeline.measurement.scheduled",
      "g=\(generation, privacy: .public) c=\(totalOutstanding, privacy: .public) w=\(cw, privacy: .public)"
    )
    if SessionTimelineTableMeasurementMode.current == .synchronous {
      measureSynchronously(
        outstanding: outstanding,
        snapshot: snapshot,
        columnWidth: columnWidth,
        generation: generation,
        totalOutstanding: totalOutstanding
      )
      return
    }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runMeasurementTask(
        outstanding: outstanding,
        snapshot: snapshot,
        columnWidth: columnWidth,
        generation: generation,
        totalOutstanding: totalOutstanding
      )
    }
    measurementTask = task
  }

  private func visibleRowIndexRange() -> Range<Int>? {
    guard let tableView, let scrollView else { return nil }
    let bounds = scrollView.contentView.bounds
    guard bounds.height > 0 else { return nil }
    let visibleRows = tableView.rows(in: bounds)
    guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return nil }
    let lower = max(0, visibleRows.location)
    let upper = min(rows.count, lower + visibleRows.length)
    return lower < upper ? lower..<upper : nil
  }

  nonisolated static let measurementPrefetchRowCount = 4

  nonisolated static func orderedMeasurementIndexes(
    rowCount: Int,
    visibleRange: Range<Int>?,
    mode: SessionTimelineTableMeasurementMode
  ) -> [Int] {
    guard rowCount > 0 else { return [] }
    guard mode == .incremental else {
      return Array(0..<rowCount)
    }
    guard let visibleRange else {
      return Array(0..<min(rowCount, measurementPrefetchRowCount))
    }
    var indexes: [Int] = []
    indexes.reserveCapacity(visibleRange.count + (measurementPrefetchRowCount * 2))
    indexes.append(contentsOf: visibleRange)
    let belowStart = visibleRange.upperBound
    let belowEnd = min(rowCount, belowStart + measurementPrefetchRowCount)
    if belowStart < belowEnd {
      indexes.append(contentsOf: belowStart..<belowEnd)
    }
    let aboveStart = max(0, visibleRange.lowerBound - measurementPrefetchRowCount)
    if aboveStart < visibleRange.lowerBound {
      indexes.append(contentsOf: aboveStart..<visibleRange.lowerBound)
    }
    return indexes
  }
}
