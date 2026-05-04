import AppKit
import Combine
import HarnessMonitorKit
import OSLog
import SwiftUI

private struct CachedRowHeight {
  let width: CGFloat
  let height: CGFloat
}

extension SessionTimelineTableView {
  // Coordinator pushes viewport state into `viewport` via methods only; it
  // never reads viewport properties from inside `updateNSView` or any path
  // SwiftUI's observation tracker can see. Reading would re-introduce the
  // body re-eval loop the model exists to break.
  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var viewport: SessionTimelineViewportModel?
    var scrollBoundaryChanged: SessionTimelineScrollBoundaryHandler

    private var rowHeightCache: [String: CachedRowHeight] = [:]
    private var lastColumnWidth: CGFloat = 0
    private var rows: [SessionTimelineRow] = []
    private var rowIndexByID: [String: Int] = [:]
    private var rowSnapshot = SessionTimelineTableSnapshot.empty
    private var actionHandler: any DecisionActionHandler = NullDecisionActionHandler()
    private weak var tableView: NSTableView?
    private weak var scrollView: NSScrollView?
    private var lastScrollCommand: SessionTimelineScrollCommand?
    private var pendingScrollCommand: SessionTimelineScrollCommand?
    private var lastViewportStats: SessionTimelineTableViewportStats?
    private var lastBoundaryState = SessionTimelineScrollBoundaryState(
      visibleMinY: .greatestFiniteMagnitude,
      visibleMaxY: 0,
      contentHeight: .greatestFiniteMagnitude
    )
    private var pendingPublish = false
    private var cancellables = Set<AnyCancellable>()
    private var measurementTask: Task<Void, Never>?
    private var measurementGeneration: Int = 0
    // Wall-clock budget for one synchronous measurement chunk. Each row's
    // SwiftUI hosting layout is variable cost (5-30ms+ depending on row
    // shape), so a fixed row count silently breaks the 100ms session-switch
    // budget on heavy variants. Yielding once a chunk has spent this many
    // milliseconds keeps the main-thread block bounded by clock time.
    private static let measurementChunkBudgetMs: Double = 12.0
    private static let signposter = OSSignposter(
      subsystem: "io.harnessmonitor",
      category: "perf"
    )
    private static let widthEqualityTolerance: CGFloat = 0.5

    init(
      viewport: SessionTimelineViewportModel,
      scrollBoundaryChanged: @escaping SessionTimelineScrollBoundaryHandler
    ) {
      self.viewport = viewport
      self.scrollBoundaryChanged = scrollBoundaryChanged
    }

    func cancelMeasurement(reason: StaticString = "external") {
      guard let task = measurementTask else { return }
      Self.signposter.emitEvent(
        "session_timeline.measurement.cancelled",
        "generation=\(measurementGeneration, privacy: .public) reason=\(reason, privacy: .public)"
      )
      task.cancel()
      measurementTask = nil
    }

    func configure(tableView: NSTableView, scrollView: NSScrollView) {
      self.tableView = tableView
      self.scrollView = scrollView
      // Defensive: if a representable re-make calls configure twice, cancel
      // the prior subscription so we never double-observe boundsDidChange.
      cancellables.removeAll()
      // AppKit posts boundsDidChangeNotification synchronously when the contentView
      // shifts, including from scroll(to:) calls inside updateNSView. Calling
      // model writes directly would mutate SwiftUI observable state during the
      // view-update phase and produce an AttributeGraph cycle; defer the publish
      // to the next runloop turn and coalesce successive notifications via
      // pendingPublish.
      NotificationCenter.default
        .publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
          Task { @MainActor in self?.boundsDidChange() }
        }
        .store(in: &cancellables)
    }

    func update(
      rows: [SessionTimelineRow],
      actionHandler: any DecisionActionHandler,
      scrollCommand: SessionTimelineScrollCommand?,
      scrollView: NSScrollView,
      columnWidth: CGFloat
    ) {
      guard let tableView else {
        return
      }
      scrollView.layoutSubtreeIfNeeded()
      let resolvedColumnWidth = SessionTimelineTableMetrics.resolvedColumnWidth(
        proposedWidth: columnWidth,
        visibleContentWidth: scrollView.contentSize.width
      )
      self.actionHandler = actionHandler
      let previousAnchor = currentVisibleAnchor()
      let nextSnapshot = SessionTimelineTableSnapshot(rows: rows)
      let rowsChanged = rowSnapshot != nextSnapshot
      if rowsChanged {
        let nextIDs = Set(rows.map(\.id))
        let priorIDs = Set(self.rows.map(\.id))
        let willReuseAny = !nextIDs.isDisjoint(with: priorIDs)
        let updateInterval = Self.signposter.beginInterval(
          "session_timeline.update_rows_changed",
          id: Self.signposter.makeSignpostID(),
          "row_count=\(rows.count, privacy: .public) reused_any=\(willReuseAny ? "true" : "false", privacy: .public) width=\(Int(resolvedColumnWidth), privacy: .public)"
        )
        defer {
          Self.signposter.endInterval("session_timeline.update_rows_changed", updateInterval)
        }

        cancelMeasurement(reason: "rows_changed")

        // Snapshot heights from currently-displayed rows whose IDs survive,
        // tagged with the width those measurements were taken at. Skip the
        // walk entirely when no IDs carry over (typical session swap), since
        // tableView.rect(ofRow:) drives AppKit layout work for each call.
        if willReuseAny {
          for rowIndex in 0..<tableView.numberOfRows {
            guard self.rows.indices.contains(rowIndex) else { continue }
            let rowID = self.rows[rowIndex].id
            guard nextIDs.contains(rowID) else { continue }
            rowHeightCache[rowID] = CachedRowHeight(
              width: lastColumnWidth,
              height: tableView.rect(ofRow: rowIndex).height
            )
          }
        }

        // Drop cached heights for IDs that are not in the next rows array so
        // the cache stays bounded across many session swaps.
        rowHeightCache = rowHeightCache.filter { nextIDs.contains($0.key) }

        self.rows = rows
        rowIndexByID = Dictionary(
          uniqueKeysWithValues: rows.enumerated().map { index, row in
            (row.id, index)
          }
        )
        rowSnapshot = nextSnapshot
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()

        // Defer per-row SwiftUI hosting-view measurement off the main thread
        // hop. Rows that miss the cache (or carry an entry tagged with a
        // different column width) return estimatedHeight from heightOfRow for
        // the first frame, which keeps session switch cost bounded by the
        // estimate-fan-out (microseconds per row) instead of the full hosting-
        // view layout cost (single-digit-to-tens-of-ms per row, multi-second
        // on large timelines). The background pass measures visible rows
        // first, then below-viewport, then above-viewport, calling
        // noteHeightOfRows per chunk so layout converges without blocking.
        if resolvedColumnWidth > 1 {
          scheduleIncrementalMeasurement(columnWidth: resolvedColumnWidth)
        }
      }
      resizeColumn(in: scrollView, columnWidth: resolvedColumnWidth)

      if scrollCommand != lastScrollCommand {
        pendingScrollCommand = scrollCommand
        lastScrollCommand = scrollCommand
      }
      if !performPendingScrollCommand() && rowsChanged {
        restore(anchor: previousAnchor)
      }
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
        abs(cached.width - lastColumnWidth) < Self.widthEqualityTolerance
      {
        return cached.height
      }
      // Cache miss (or width tag stale): return the static estimate without
      // invoking the SwiftUI hosting-view layout. The incremental measurement
      // task fills in real heights asynchronously and calls noteHeightOfRows
      // per chunk so layout converges without blocking the session switch.
      return SessionTimelineTableMetrics.estimatedHeight(for: rowData)
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
      cell.update(row: rows[row], actionHandler: actionHandler)
      return cell
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
      SessionTimelineTableRowView()
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
      false
    }

    private func boundsDidChange() {
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
      guard columnWidth > 1, column.width != columnWidth else { return }
      let isFirstRealWidth = lastColumnWidth <= 1
      let widthChanged =
        !isFirstRealWidth && abs(columnWidth - lastColumnWidth) > Self.widthEqualityTolerance
      let needsFullRefresh = isFirstRealWidth || widthChanged
      lastColumnWidth = columnWidth
      column.width = columnWidth
      if needsFullRefresh {
        // Width-tagged cache lookups will treat any prior entries as stale and
        // fall back to estimate, so no explicit cache flush is required - the
        // background measurement pass overwrites entries with the new width.
        cancelMeasurement(reason: widthChanged ? "width_changed" : "first_real_width")
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<rows.count))
        scheduleIncrementalMeasurement(columnWidth: columnWidth)
      } else {
        // Same width but column reapplied (e.g., row reload). Visible rows are
        // sufficient to refresh layout.
        invalidateVisibleRowHeights()
      }
    }

    private func scheduleIncrementalMeasurement(columnWidth: CGFloat) {
      guard columnWidth > 1, !rows.isEmpty else {
        return
      }
      let snapshot = rows
      let visibleRange = visibleRowIndexRange()
      let measurementOrder = orderedMeasurementIndexes(
        rowCount: snapshot.count,
        visibleRange: visibleRange
      )
      // Skip rows that already have a cached entry tagged with this width,
      // so partial updates don't redo work for unchanged rows.
      let outstanding = measurementOrder.filter { index in
        guard snapshot.indices.contains(index) else { return false }
        let id = snapshot[index].id
        guard let cached = rowHeightCache[id] else { return true }
        return abs(cached.width - columnWidth) >= Self.widthEqualityTolerance
      }
      guard !outstanding.isEmpty else {
        return
      }
      cancelMeasurement(reason: "reschedule")
      self.measurementGeneration &+= 1
      let generation = self.measurementGeneration
      let totalOutstanding = outstanding.count
      Self.signposter.emitEvent(
        "session_timeline.measurement.scheduled",
        "generation=\(generation, privacy: .public) outstanding=\(totalOutstanding, privacy: .public) width=\(Int(columnWidth), privacy: .public)"
      )
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        var cursor = 0
        while cursor < outstanding.count {
          if Task.isCancelled { return }
          let chunkInterval = Self.signposter.beginInterval(
            "session_timeline.measurement.chunk",
            id: Self.signposter.makeSignpostID(),
            "generation=\(generation, privacy: .public) cursor=\(cursor, privacy: .public)"
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
          Self.signposter.endInterval(
            "session_timeline.measurement.chunk",
            chunkInterval,
            "measured=\(measuredInChunk, privacy: .public) remaining=\(outstanding.count - cursor, privacy: .public)"
          )
          await Task.yield()
        }
        if !Task.isCancelled {
          Self.signposter.emitEvent(
            "session_timeline.measurement.completed",
            "generation=\(generation, privacy: .public) measured=\(totalOutstanding, privacy: .public)"
          )
          self.measurementTask = nil
        }
      }
      measurementTask = task
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
      let duration = start.duration(to: ContinuousClock.now)
      let (seconds, attoseconds) = duration.components
      return Double(seconds) * 1_000.0 + Double(attoseconds) / 1_000_000_000_000_000.0
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

    private func performPendingScrollCommand() -> Bool {
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
    private func scrollToTarget(_ rowID: String) -> Bool {
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

    private func restore(anchor: SessionTimelineTableAnchor?) {
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

    private func clampedScrollY(_ y: CGFloat, scrollView: NSScrollView) -> CGFloat {
      guard let tableView else {
        return 0
      }
      return SessionTimelineTableMetrics.clampedScrollY(
        y,
        contentHeight: tableView.bounds.height,
        viewportHeight: scrollView.contentSize.height
      )
    }

    private func invalidateVisibleRowHeights() {
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

    private func currentVisibleAnchor() -> SessionTimelineTableAnchor? {
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

    private func publishViewportState() {
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

    private func anchorRowID(for visibleRows: NSRange) -> String? {
      guard visibleRows.location != NSNotFound,
        rows.indices.contains(visibleRows.location)
      else {
        return nil
      }
      return rows[visibleRows.location].id
    }
  }
}
