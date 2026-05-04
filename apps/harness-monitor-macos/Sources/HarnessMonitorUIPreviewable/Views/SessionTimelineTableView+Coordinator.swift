import AppKit
import Combine
import HarnessMonitorKit
import OSLog
import SwiftUI

extension SessionTimelineTableView {
  // Coordinator pushes viewport state into `viewport` via methods only; it
  // never reads viewport properties from inside `updateNSView` or any path
  // SwiftUI's observation tracker can see. Reading would re-introduce the
  // body re-eval loop the model exists to break.
  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var viewport: SessionTimelineViewportModel?
    var scrollBoundaryChanged: SessionTimelineScrollBoundaryHandler

    var rowHeightCache: [String: CachedRowHeight] = [:]
    private var lastColumnWidth: CGFloat = 0
    var rows: [SessionTimelineRow] = []
    var rowIndexByID: [String: Int] = [:]
    private var rowSnapshot = SessionTimelineTableSnapshot.empty
    private var actionHandler: any DecisionActionHandler = NullDecisionActionHandler()
    weak var tableView: NSTableView?
    weak var scrollView: NSScrollView?
    private var lastScrollCommand: SessionTimelineScrollCommand?
    var pendingScrollCommand: SessionTimelineScrollCommand?
    var lastViewportStats: SessionTimelineTableViewportStats?
    var lastBoundaryState = SessionTimelineScrollBoundaryState(
      visibleMinY: .greatestFiniteMagnitude,
      visibleMaxY: 0,
      contentHeight: .greatestFiniteMagnitude
    )
    private var pendingPublish = false
    private var cancellables = Set<AnyCancellable>()
    var measurementTask: Task<Void, Never>?
    private var measurementGeneration: Int = 0

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
        "generation=\(self.measurementGeneration, privacy: .public) reason=\(reason, privacy: .public)"
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
        let rowCount = rows.count
        let reuseAny = willReuseAny
        let colWidth = Int(resolvedColumnWidth)
        let updateInterval = Self.signposter.beginInterval(
          "session_timeline.update_rows_changed",
          id: Self.signposter.makeSignpostID(),
          "n=\(rowCount, privacy: .public) r=\(reuseAny, privacy: .public) w=\(colWidth, privacy: .public)"
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
      let cw = Int(columnWidth)
      Self.signposter.emitEvent(
        "session_timeline.measurement.scheduled",
        "g=\(generation, privacy: .public) c=\(totalOutstanding, privacy: .public) w=\(cw, privacy: .public)"
      )
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
}
