import AppKit
import Combine
import HarnessMonitorKit
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

    private var rowHeightCache: [String: CGFloat] = [:]
    private var lastColumnWidth: CGFloat = 0
    private var lastPreMeasuredWidth: CGFloat = 0
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

    init(
      viewport: SessionTimelineViewportModel,
      scrollBoundaryChanged: @escaping SessionTimelineScrollBoundaryHandler
    ) {
      self.viewport = viewport
      self.scrollBoundaryChanged = scrollBoundaryChanged
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
        for rowIndex in 0..<tableView.numberOfRows {
          guard self.rows.indices.contains(rowIndex) else { continue }
          let rowID = self.rows[rowIndex].id
          rowHeightCache[rowID] = tableView.rect(ofRow: rowIndex).height
        }

        // Measure with the scroll view's clip width, not the outer SwiftUI width.
        // The always-visible vertical scroller shrinks the real proposal enough to
        // flip ViewThatFits into compact mode for long signal rows; if measurement
        // uses the larger width, AppKit caches a short row that clips the source
        // label and detail once rendered.
        if resolvedColumnWidth > 1 {
          lastPreMeasuredWidth = resolvedColumnWidth
          autoreleasepool {
            for row in rows where rowHeightCache[row.id] == nil {
              rowHeightCache[row.id] = SessionTimelineTableCellView.measuredHeight(
                for: row,
                columnWidth: resolvedColumnWidth
              )
            }
          }
        }

        self.rows = rows
        rowIndexByID = Dictionary(
          uniqueKeysWithValues: rows.enumerated().map { index, row in
            (row.id, index)
          }
        )
        rowSnapshot = nextSnapshot
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
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
      if let cached = rowHeightCache[rowData.id] {
        return cached
      }
      // Lazy path: cache was nil (width was ≤1 when rowsChanged ran).
      // resizeColumn sets lastColumnWidth before calling noteHeightOfRows, so
      // lastColumnWidth is always valid here — unlike scrollView.contentView.bounds.width
      // which may still be zero until AppKit completes its first layout pass.
      if lastColumnWidth > 1 {
        let measuredHeight = SessionTimelineTableCellView.measuredHeight(
          for: rowData,
          columnWidth: lastColumnWidth
        )
        rowHeightCache[rowData.id] = measuredHeight
        return measuredHeight
      }
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
      lastColumnWidth = columnWidth
      column.width = columnWidth
      if isFirstRealWidth {
        // First layout with a valid width. If rowsChanged already pre-measured at
        // this exact width, the cache is correct — just notify AppKit. Otherwise
        // (columnWidth changed between pre-measure and resizeColumn, edge case),
        // discard stale cache so heightOfRow remeasures at the current width.
        if lastPreMeasuredWidth != columnWidth {
          for row in rows { rowHeightCache.removeValue(forKey: row.id) }
        }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<rows.count))
      } else {
        // Subsequent window resize: updating visible rows is sufficient.
        invalidateVisibleRowHeights()
      }
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
      // Evict cached heights so heightOfRow remeasures at the new column width.
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
