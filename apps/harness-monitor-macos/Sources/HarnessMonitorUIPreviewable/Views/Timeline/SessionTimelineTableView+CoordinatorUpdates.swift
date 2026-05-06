import AppKit
import Combine
import HarnessMonitorKit
import OSLog
import SwiftUI

extension SessionTimelineTableView.Coordinator {
  func update(
    rows: [SessionTimelineRow],
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)?,
    scrollCommand: SessionTimelineScrollCommand?,
    request: SessionTimelineTableView.UpdateRequest
  ) {
    guard tableView != nil else {
      return
    }
    request.scrollView.layoutSubtreeIfNeeded()
    let resolvedColumnWidth = SessionTimelineTableMetrics.resolvedColumnWidth(
      proposedWidth: request.columnWidth,
      visibleContentWidth: request.scrollView.contentSize.width
    )
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    let fontScaleChanged = abs(self.fontScale - request.fontScale) > 0.001
    self.fontScale = request.fontScale
    let wasPinnedToLatest = isPinnedToLatestViewport()
    let previousAnchor = wasPinnedToLatest ? nil : currentVisibleAnchor()
    let nextSnapshot = SessionTimelineTableSnapshot(rows: rows)
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
    if wasPinnedToLatest && !hasUnfulfilledScrollCommand {
      normalizePinnedLatestViewportIfNeeded()
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
    let measurementOrder = orderedMeasurementIndexes(
      rowCount: snapshot.count,
      visibleRange: visibleRange
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

  private func orderedMeasurementIndexes(
    rowCount: Int,
    visibleRange: Range<Int>?
  ) -> [Int] {
    guard rowCount > 0 else { return [] }
    guard let visibleRange else {
      return Array(0..<rowCount)
    }
    var indexes: [Int] = []
    indexes.reserveCapacity(rowCount)
    indexes.append(contentsOf: visibleRange)
    let belowStart = visibleRange.upperBound
    if belowStart < rowCount {
      indexes.append(contentsOf: belowStart..<rowCount)
    }
    if visibleRange.lowerBound > 0 {
      indexes.append(contentsOf: 0..<visibleRange.lowerBound)
    }
    return indexes
  }
}
