import AppKit
import HarnessMonitorKit
import OSLog

struct CachedRowHeight {
  let width: CGFloat
  let height: CGFloat
}

extension SessionTimelineTableView.Coordinator {
  // Wall-clock budget for one synchronous measurement chunk. Each row's
  // SwiftUI hosting layout is variable cost (5-30ms+ depending on row
  // shape), so a fixed row count silently breaks the 100ms session-switch
  // budget on heavy variants. Yielding once a chunk has spent this many
  // milliseconds keeps the main-thread block bounded by clock time.
  static let measurementChunkBudgetMs: Double = 12.0
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
            abs(cached.width - columnWidth) < Self.widthEqualityTolerance
          {
            continue
          }
          let height = SessionTimelineTableCellView.measuredHeight(
            for: row,
            columnWidth: columnWidth
          )
          self.rowHeightCache[row.id] = CachedRowHeight(
            width: columnWidth,
            height: height
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
        self.tableView?.noteHeightOfRows(withIndexesChanged: changedIndexes)
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
      Self.signposter.emitEvent(
        "session_timeline.measurement.completed",
        "g=\(generation, privacy: .public) m=\(totalOutstanding, privacy: .public)"
      )
      self.measurementTask = nil
    }
  }
}
