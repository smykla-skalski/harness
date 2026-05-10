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
  // Wall-clock budget for one synchronous measurement chunk. Each row's
  // SwiftUI hosting layout is variable cost (5-30ms+ depending on row
  // shape), so a fixed row count silently breaks the 100ms session-switch
  // budget on heavy variants. Yielding once a chunk has spent this many
  // milliseconds keeps the main-thread block bounded by clock time.
  static let measurementChunkBudgetMs: Double = 12.0
  static let widthAnimationMeasurementDebounceNs: UInt64 = 120_000_000
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
    var cursor = 0
    while cursor < outstanding.count {
      if Task.isCancelled { return }
      let chunkInterval = Self.signposter.beginInterval(
        "session_timeline.measurement.chunk",
        id: Self.signposter.makeSignpostID(),
        "g=\(generation, privacy: .public) cur=\(cursor, privacy: .public)"
      )
      var changedIndexes = IndexSet()
      var measuredInChunk = 0
      autoreleasepool {
        let chunkStart = ContinuousClock.now
        while cursor < outstanding.count {
          let rowIndex = outstanding[cursor]
          cursor += 1
          guard self.rows.indices.contains(rowIndex),
            self.rows[rowIndex].id == snapshot[rowIndex].id
          else { continue }
          let row = snapshot[rowIndex]
          if let cached = self.rowHeightCache[row.id],
            !cached.requiresMeasurement(for: columnWidth, tolerance: Self.widthEqualityTolerance)
          {
            continue
          }
          let height = SessionTimelineTableCellView.measuredHeight(
            for: row,
            columnWidth: columnWidth,
            fontScale: fontScale
          )
          self.rowHeightCache[row.id] = CachedRowHeight(
            width: columnWidth,
            height: height,
            isMeasured: true
          )
          changedIndexes.insert(rowIndex)
          measuredInChunk += 1
          let elapsedMs = Self.elapsedMilliseconds(since: chunkStart)
          if elapsedMs >= Self.measurementChunkBudgetMs {
            break
          }
        }
      }
      if !changedIndexes.isEmpty {
        applyMeasuredHeights(changedIndexes)
      }
      let remaining = outstanding.count - cursor
      Self.signposter.endInterval(
        "session_timeline.measurement.chunk",
        chunkInterval,
        "m=\(measuredInChunk, privacy: .public) r=\(remaining, privacy: .public)"
      )
      await Task.yield()
    }
    if !Task.isCancelled {
      completeMeasurementTask(
        generation: generation,
        totalOutstanding: totalOutstanding,
        columnWidth: columnWidth
      )
    }
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
        let height = SessionTimelineTableCellView.measuredHeight(
          for: row,
          columnWidth: columnWidth,
          fontScale: fontScale
        )
        self.rowHeightCache[row.id] = CachedRowHeight(
          width: columnWidth,
          height: height,
          isMeasured: true
        )
        changedIndexes.insert(rowIndex)
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

  private func applyMeasuredHeights(_ changedIndexes: IndexSet) {
    guard !changedIndexes.isEmpty else { return }
    let affectsVisibleRows = changedIndexesAffectVisibleRows(changedIndexes)
    performWithoutTableAnimation {
      tableView?.noteHeightOfRows(withIndexesChanged: changedIndexes)
      if affectsVisibleRows {
        tableView?.layoutSubtreeIfNeeded()
        scrollView?.layoutSubtreeIfNeeded()
      }
    }
    guard affectsVisibleRows else {
      return
    }
    if isPinnedToLatestViewport() {
      _ = normalizePinnedLatestViewportIfNeeded()
    }
    boundsDidChange()
  }

  private func changedIndexesAffectVisibleRows(_ changedIndexes: IndexSet) -> Bool {
    guard
      let tableView,
      let scrollView
    else {
      return false
    }
    let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
    guard visibleRows.location != NSNotFound, visibleRows.length > 0 else {
      return false
    }
    let visibleIndexes = IndexSet(
      integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length)
    )
    return !visibleIndexes.isDisjoint(with: changedIndexes)
  }

  func visibleRowsNeedMeasurement(columnWidth: CGFloat) -> Bool {
    guard
      let tableView,
      let scrollView,
      columnWidth > 1
    else {
      return false
    }
    let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
    guard visibleRows.location != NSNotFound, visibleRows.length > 0 else {
      return false
    }
    let rowRange = visibleRows.location..<(visibleRows.location + visibleRows.length)
    for rowIndex in rowRange where rows.indices.contains(rowIndex) {
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
