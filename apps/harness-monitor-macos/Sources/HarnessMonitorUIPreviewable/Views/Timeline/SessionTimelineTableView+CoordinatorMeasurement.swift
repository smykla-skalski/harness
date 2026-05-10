import AppKit
import HarnessMonitorKit
import OSLog

struct CachedRowHeight {
  let width: CGFloat
  let height: CGFloat
  let isMeasured: Bool

  func matches(width: CGFloat, tolerance: CGFloat) -> Bool {
    abs(self.width - width) < tolerance
  }

  func requiresMeasurement(for width: CGFloat, tolerance: CGFloat) -> Bool {
    !matches(width: width, tolerance: tolerance) || !isMeasured
  }
}

enum SessionTimelineTableMeasurementMode: Equatable {
  case incremental
  case synchronous

  static func resolve(environment: [String: String]) -> Self {
    switch HarnessMonitorLaunchMode(environment: environment) {
    case .preview:
      .synchronous
    case .live, .empty:
      .incremental
    }
  }

  static let current = resolve(environment: ProcessInfo.processInfo.environment)
}

extension SessionTimelineTableView.Coordinator {
  private struct MeasurementChunkResult {
    let changedIndexes: IndexSet
    let measuredCount: Int
    let remainingCount: Int
  }

  // Wall-clock budget for one synchronous measurement chunk. Each row's
  // SwiftUI hosting layout is variable cost (5-30ms+ depending on row
  // shape), so a fixed row count silently breaks the 100ms session-switch
  // budget on heavy variants. Yielding once a chunk has spent this many
  // milliseconds keeps the main-thread block bounded by clock time.
  static let measurementChunkBudgetMs: Double = 6.0
  static let measurementChunkPauseNs: UInt64 = 8_000_000
  static let widthAnimationMeasurementDebounceNs: UInt64 = 180_000_000
  static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )
  static let widthEqualityTolerance: CGFloat = 0.5

  static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: ContinuousClock.now)
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1_000.0 + Double(attoseconds) / 1_000_000_000_000_000.0
  }

  func performWithoutTableAnimation(_ updates: () -> Void) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      context.allowsImplicitAnimation = false
      updates()
    }
  }

  func runMeasurementTask(
    outstanding: [Int],
    snapshot: [SessionTimelineRow],
    columnWidth: CGFloat,
    generation: Int,
    totalOutstanding: Int
  ) async {
    guard isMeasurementColumnWidthCurrent(columnWidth) else {
      return
    }
    var cursor = 0
    while cursor < outstanding.count {
      if Task.isCancelled || !isMeasurementColumnWidthCurrent(columnWidth) { return }
      let chunkInterval = Self.signposter.beginInterval(
        "session_timeline.measurement.chunk",
        id: Self.signposter.makeSignpostID(),
        "g=\(generation, privacy: .public) cur=\(cursor, privacy: .public)"
      )
      let chunk = measureNextChunk(
        outstanding: outstanding,
        snapshot: snapshot,
        columnWidth: columnWidth,
        cursor: &cursor
      )
      guard applyMeasuredHeightsIfCurrent(chunk.changedIndexes, columnWidth: columnWidth) else {
        return
      }
      Self.signposter.endInterval(
        "session_timeline.measurement.chunk",
        chunkInterval,
        "m=\(chunk.measuredCount, privacy: .public) r=\(chunk.remainingCount, privacy: .public)"
      )
      guard await pauseAfterMeasurementChunk(remaining: chunk.remainingCount) else {
        return
      }
    }
    if !Task.isCancelled, isMeasurementColumnWidthCurrent(columnWidth) {
      completeMeasurementTask(
        generation: generation,
        totalOutstanding: totalOutstanding,
        columnWidth: columnWidth
      )
    }
  }

  private func measureNextChunk(
    outstanding: [Int],
    snapshot: [SessionTimelineRow],
    columnWidth: CGFloat,
    cursor: inout Int
  ) -> MeasurementChunkResult {
    var changedIndexes = IndexSet()
    var measuredCount = 0
    autoreleasepool {
      let chunkStart = ContinuousClock.now
      while cursor < outstanding.count {
        let rowIndex = outstanding[cursor]
        cursor += 1
        guard let row = measurementRow(at: rowIndex, snapshot: snapshot) else {
          continue
        }
        guard rowRequiresMeasurement(row, columnWidth: columnWidth) else {
          continue
        }
        if cacheMeasuredHeight(for: row, columnWidth: columnWidth) {
          changedIndexes.insert(rowIndex)
        }
        measuredCount += 1
        if Self.elapsedMilliseconds(since: chunkStart) >= Self.measurementChunkBudgetMs {
          break
        }
      }
    }
    return MeasurementChunkResult(
      changedIndexes: changedIndexes,
      measuredCount: measuredCount,
      remainingCount: outstanding.count - cursor
    )
  }

  private func measurementRow(
    at rowIndex: Int,
    snapshot: [SessionTimelineRow]
  ) -> SessionTimelineRow? {
    guard rows.indices.contains(rowIndex),
      snapshot.indices.contains(rowIndex),
      rows[rowIndex].id == snapshot[rowIndex].id
    else {
      return nil
    }
    return snapshot[rowIndex]
  }

  func rowRequiresMeasurement(
    _ row: SessionTimelineRow,
    columnWidth: CGFloat
  ) -> Bool {
    guard let cached = rowHeightCache[row.id] else {
      return true
    }
    return cached.requiresMeasurement(for: columnWidth, tolerance: Self.widthEqualityTolerance)
  }

  @discardableResult
  func cacheMeasuredHeight(for row: SessionTimelineRow, columnWidth: CGFloat) -> Bool {
    let height = SessionTimelineTableCellView.measuredHeight(
      for: row,
      columnWidth: columnWidth,
      fontScale: fontScale
    )
    let previousHeight = currentTableHeight(for: row, columnWidth: columnWidth)
    rowHeightCache[row.id] = CachedRowHeight(
      width: columnWidth,
      height: height,
      isMeasured: true
    )
    return abs(previousHeight - height) > 0.5
  }

  private func currentTableHeight(for row: SessionTimelineRow, columnWidth: CGFloat) -> CGFloat {
    guard let cached = rowHeightCache[row.id],
      cached.matches(width: columnWidth, tolerance: Self.widthEqualityTolerance)
    else {
      return SessionTimelineTableMetrics.estimatedHeight(for: row, fontScale: fontScale)
    }
    return cached.height
  }

  private func pauseAfterMeasurementChunk(remaining: Int) async -> Bool {
    guard remaining > 0 else {
      await Task.yield()
      return true
    }
    do {
      try await Task.sleep(nanoseconds: Self.measurementChunkPauseNs)
      return true
    } catch {
      return false
    }
  }

  private func applyMeasuredHeightsIfCurrent(
    _ changedIndexes: IndexSet,
    columnWidth: CGFloat
  ) -> Bool {
    guard !changedIndexes.isEmpty else {
      return true
    }
    guard isMeasurementColumnWidthCurrent(columnWidth) else {
      return false
    }
    applyMeasuredHeights(changedIndexes)
    return true
  }

  func isMeasurementColumnWidthCurrent(_ columnWidth: CGFloat) -> Bool {
    abs(columnWidth - lastColumnWidth) < Self.widthEqualityTolerance
  }

  func measureSynchronously(
    outstanding: [Int],
    snapshot: [SessionTimelineRow],
    columnWidth: CGFloat,
    generation: Int,
    totalOutstanding: Int
  ) {
    var changedIndexes = IndexSet()
    autoreleasepool {
      for rowIndex in outstanding {
        guard self.rows.indices.contains(rowIndex),
          self.rows[rowIndex].id == snapshot[rowIndex].id
        else { continue }
        let row = snapshot[rowIndex]
        if let cached = self.rowHeightCache[row.id],
          !cached.requiresMeasurement(for: columnWidth, tolerance: Self.widthEqualityTolerance)
        {
          continue
        }
        if self.cacheMeasuredHeight(for: row, columnWidth: columnWidth) {
          changedIndexes.insert(rowIndex)
        }
      }
    }
    if !changedIndexes.isEmpty {
      applyMeasuredHeights(changedIndexes)
    }
    completeMeasurementTask(
      generation: generation,
      totalOutstanding: totalOutstanding,
      columnWidth: columnWidth
    )
  }

  private func completeMeasurementTask(
    generation: Int,
    totalOutstanding: Int,
    columnWidth: CGFloat
  ) {
    persistHeightCache()
    Self.signposter.emitEvent(
      "session_timeline.measurement.completed",
      "g=\(generation, privacy: .public) m=\(totalOutstanding, privacy: .public)"
    )
    measurementTask = nil
    scheduleVisibleRowsMeasurementIfNeeded(columnWidth: columnWidth)
  }

  private func scheduleVisibleRowsMeasurementIfNeeded(columnWidth: CGFloat) {
    guard visibleRowsNeedMeasurement(columnWidth: columnWidth) else {
      return
    }
    scheduleIncrementalMeasurement(columnWidth: columnWidth)
  }

  func applyMeasuredHeights(_ changedIndexes: IndexSet) {
    guard !changedIndexes.isEmpty else { return }
    guard !isViewportMoving else {
      pendingHeightInvalidationIndexes.formUnion(changedIndexes)
      boundsDidChange(forceObservedStats: true, suppressBoundaryCallbacks: true)
      return
    }
    applyMeasuredHeightInvalidations(changedIndexes)
  }

  func flushPendingHeightInvalidations() {
    let indexes = pendingHeightInvalidationIndexes
    pendingHeightInvalidationIndexes = []
    applyMeasuredHeightInvalidations(indexes)
  }

  private func applyMeasuredHeightInvalidations(_ changedIndexes: IndexSet) {
    guard !changedIndexes.isEmpty else { return }
    let viewportImpact = viewportImpact(forChangedIndexes: changedIndexes)
    let wasPinnedToLatest = isPinnedToLatestViewport()
    let anchor = wasPinnedToLatest ? nil : currentVisibleAnchor()
    let tableIndexes = tableRows(forDataIndexes: changedIndexes)
    performWithoutTableAnimation {
      tableView?.noteHeightOfRows(withIndexesChanged: tableIndexes)
      refreshCurrentVirtualLayout(columnWidth: lastColumnWidth)
      if viewportImpact.affectsPosition {
        tableView?.layoutSubtreeIfNeeded()
        scrollView?.layoutSubtreeIfNeeded()
      }
    }
    guard viewportImpact.affectsPosition else {
      return
    }
    if wasPinnedToLatest {
      if !normalizePinnedLatestViewportIfNeeded() {
        boundsDidChange(forceObservedStats: true, suppressBoundaryCallbacks: true)
      }
    } else {
      restore(anchor: anchor)
    }
  }

  private func viewportImpact(forChangedIndexes changedIndexes: IndexSet) -> ViewportImpact {
    guard let visibleRows = visibleDataRowRange() else {
      return .none
    }
    let firstVisibleRow = visibleRows.lowerBound
    let visibleUpperBound = visibleRows.upperBound
    for index in changedIndexes {
      if index < visibleUpperBound {
        return .affectsPosition
      }
      if index >= firstVisibleRow {
        return .belowViewport
      }
    }
    return .none
  }

  func visibleRowsNeedMeasurement(columnWidth: CGFloat) -> Bool {
    guard columnWidth > 1 else {
      return false
    }
    guard let visibleRows = visibleDataRowRange() else {
      return false
    }
    for rowIndex in visibleRows where rows.indices.contains(rowIndex) {
      let rowID = rows[rowIndex].id
      if rowHeightCache[rowID]?.requiresMeasurement(
        for: columnWidth,
        tolerance: Self.widthEqualityTolerance
      ) ?? true {
        return true
      }
    }
    return false
  }
}

private enum ViewportImpact {
  case none
  case belowViewport
  case affectsPosition

  var affectsPosition: Bool {
    self == .affectsPosition
  }
}
