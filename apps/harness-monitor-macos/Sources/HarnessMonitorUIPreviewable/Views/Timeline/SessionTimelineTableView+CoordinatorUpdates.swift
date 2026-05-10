import AppKit
import Combine
import HarnessMonitorKit
import OSLog
import SwiftUI

extension SessionTimelineTableView.Coordinator {
  func update(
    rows: [SessionTimelineRow],
    virtualization: SessionTimelineTableVirtualization = .disabled,
    contentIdentity: SessionTimelineContentIdentity? = nil,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)?,
    scrollCommand: SessionTimelineScrollCommand?,
    request: SessionTimelineTableView.UpdateRequest
  ) {
    guard tableView != nil else {
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
    let resolvedColumnWidth = resolvedColumnWidth(for: request)
    let widthDelta = abs(resolvedColumnWidth - lastColumnWidth)
    let widthSame = widthDelta < Self.widthEqualityTolerance
    let fontSame = abs(request.fontScale - fontScale) < 0.001
    let scrollSame = scrollCommand == lastScrollCommand && pendingScrollCommand == nil
    let identitySame = contentIdentity == heightCacheIdentity
    let virtualizationSame = virtualization == self.virtualization

    if rowsLookSame, widthSame, fontSame, scrollSame, identitySame, virtualizationSame {
      return
    }

    // Width-only path: during animation the only thing that changes per frame
    // is the proposed column width. Apply it smoothly to the AppKit column
    // and reschedule the measurement task (which auto-debounces by cancelling
    // its predecessor) without invalidating heights via noteHeightOfRows. The
    // per-tick noteHeightOfRows call was the source of the reveal stall.
    if rowsLookSame, fontSame, scrollSame, identitySame, virtualizationSame {
      applyWidthOnlyUpdateIfNeeded(columnWidth: resolvedColumnWidth)
      return
    }

    let previousFontScale = fontScale
    let wasPinnedToLatest = isPinnedToLatestViewport()
    let previousAnchor = currentVisibleAnchor()
    let previousVisibleAnchors = currentVisibleAnchors()
    let rollingRowChange = SessionTimelineRollingRowChange.detect(
      previousRows: self.rows,
      nextRows: rows
    )
    let rollingAnchor = rollingRowChange?.restorationAnchor(
      primary: wasPinnedToLatest ? nil : previousAnchor,
      visibleAnchors: previousVisibleAnchors,
      nextRows: rows
    )
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
    let rowsChanged = rowSnapshot != nextSnapshot || fontScaleChanged || !virtualizationSame
    if rowsChanged {
      applyRowChanges(
        rows: rows,
        virtualization: virtualization,
        nextSnapshot: nextSnapshot,
        invalidatedHeightIDs: invalidatedHeightIDs,
        priorIDs: Set(self.rows.map(\.id)),
        restorationAnchorID: rollingAnchor?.rowID
          ?? (wasPinnedToLatest ? nil : previousAnchor?.rowID),
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
        previousAnchor: previousAnchor,
        rollingRowChange: rollingRowChange,
        rollingAnchor: rollingAnchor
      )
    }
  }

  private func applyRowChanges(
    rows: [SessionTimelineRow],
    virtualization: SessionTimelineTableVirtualization,
    nextSnapshot: SessionTimelineTableSnapshot,
    invalidatedHeightIDs: Set<String>,
    priorIDs: Set<String>,
    restorationAnchorID: String?,
    resolvedColumnWidth: CGFloat,
    fontScaleChanged: Bool
  ) {
    guard let tableView else {
      return
    }
    let nextIDs = Set(rows.map(\.id))
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
    rowHeightCache = rowHeightCache.filter {
      nextIDs.contains($0.key) && !invalidatedHeightIDs.contains($0.key)
        && $0.value.isMeasured
    }
    prepareColumnForRowReload(columnWidth: resolvedColumnWidth)
    premeasureRowsBeforeReload(
      rows: rows,
      priorIDs: priorIDs,
      invalidatedHeightIDs: invalidatedHeightIDs,
      restorationAnchorID: restorationAnchorID,
      columnWidth: resolvedColumnWidth
    )
    let nextEventOffsets = eventOffsets(for: rows)
    _ = refreshVirtualSpacers(
      rows: rows,
      eventOffsets: nextEventOffsets,
      virtualization: virtualization,
      columnWidth: resolvedColumnWidth
    )

    self.rows = rows
    eventOffsetsByRow = nextEventOffsets
    rowIndexByID = Dictionary(
      uniqueKeysWithValues: rows.enumerated().map { index, row in
        (row.id, index)
      }
    )
    rowSnapshot = nextSnapshot
    performWithoutTableAnimation {
      tableView.reloadData()
    }
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
      knownEventHeights = [:]
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

  private func restoreViewportAfterRowChange(
    hasUnfulfilledScrollCommand: Bool,
    wasPinnedToLatest: Bool,
    previousAnchor: SessionTimelineTableAnchor?,
    rollingRowChange: SessionTimelineRollingRowChange?,
    rollingAnchor: SessionTimelineTableAnchor?
  ) {
    if !hasUnfulfilledScrollCommand, rollingRowChange != nil {
      if let rollingAnchor {
        restore(anchor: rollingAnchor)
      } else {
        boundsDidChange(forceObservedStats: true, suppressBoundaryCallbacks: true)
      }
      return
    }
    if wasPinnedToLatest && !hasUnfulfilledScrollCommand {
      if !normalizePinnedLatestViewportIfNeeded() {
        boundsDidChange(forceObservedStats: true, suppressBoundaryCallbacks: true)
      }
      return
    }
    if let previousAnchor {
      restore(anchor: previousAnchor)
    } else {
      boundsDidChange(forceObservedStats: true)
    }
  }

  func numberOfRows(in _: NSTableView) -> Int {
    tableRowCount
  }

  func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
    if let spacerHeight = virtualSpacerHeight(forTableRow: row) {
      return spacerHeight
    }
    guard let dataIndex = dataIndex(forTableRow: row), rows.indices.contains(dataIndex) else {
      return SessionTimelineTableMetrics.estimatedBaseRowHeight
    }
    let rowData = rows[dataIndex]
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
    if virtualSpacerHeight(forTableRow: row) != nil {
      return makeSpacerCell(in: tableView)
    }
    guard let dataIndex = dataIndex(forTableRow: row), rows.indices.contains(dataIndex) else {
      return nil
    }
    let cell =
      tableView.makeView(
        withIdentifier: SessionTimelineTableCellView.cellIdentifier,
        owner: self
      ) as? SessionTimelineTableCellView
      ?? SessionTimelineTableCellView()
    let connectorVisibility = SessionTimelineTableMetrics.connectorVisibility(
      rowIndex: dataIndex,
      rowCount: rows.count
    )
    cell.update(
      row: rows[dataIndex],
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

  func scheduleIncrementalMeasurement(
    columnWidth: CGFloat,
    debounceNanoseconds: UInt64 = 0
  ) {
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
      if debounceNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: debounceNanoseconds)
        guard !Task.isCancelled else { return }
      }
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

  func visibleRowIndexRange() -> Range<Int>? {
    visibleDataRowRange()
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
