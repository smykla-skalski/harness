import AppKit
import HarnessMonitorKit
import SwiftUI

extension SessionTimelineTableView {
  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var viewportStatsChanged: (SessionTimelineTableViewportStats) -> Void
    var scrollBoundaryChanged: SessionTimelineScrollBoundaryHandler

    private var rowHeightCache: [String: CGFloat] = [:]
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

    init(
      viewportStatsChanged: @escaping (SessionTimelineTableViewportStats) -> Void,
      scrollBoundaryChanged: @escaping SessionTimelineScrollBoundaryHandler
    ) {
      self.viewportStatsChanged = viewportStatsChanged
      self.scrollBoundaryChanged = scrollBoundaryChanged
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    func configure(tableView: NSTableView, scrollView: NSScrollView) {
      self.tableView = tableView
      self.scrollView = scrollView
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(contentBoundsDidChange(_:)),
        name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView
      )
    }

    func update(
      rows: [SessionTimelineRow],
      actionHandler: any DecisionActionHandler,
      scrollCommand: SessionTimelineScrollCommand?,
      scrollView: NSScrollView
    ) {
      guard let tableView else {
        return
      }
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

        self.rows = rows
        rowIndexByID = Dictionary(
          uniqueKeysWithValues: rows.enumerated().map { index, row in
            (row.id, index)
          }
        )
        rowSnapshot = nextSnapshot
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
      } else {
        refreshVisibleRows()
      }
      if resizeColumn(in: scrollView) {
        invalidateVisibleRowHeights()
      }

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

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard rows.indices.contains(row) else {
        return SessionTimelineTableMetrics.estimatedBaseRowHeight
      }
      let rowData = rows[row]
      if let cached = rowHeightCache[rowData.id] {
        return cached
      }
      return SessionTimelineTableMetrics.estimatedHeight(for: rowData)
    }

    func tableView(
      _ tableView: NSTableView,
      viewFor tableColumn: NSTableColumn?,
      row: Int
    ) -> NSView? {
      _ = tableColumn
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

    @objc
    private func contentBoundsDidChange(_: Notification) {
      publishViewportState()
    }

    private func resizeColumn(in scrollView: NSScrollView) -> Bool {
      guard let tableView, let column = tableView.tableColumns.first else {
        return false
      }
      let width = max(1, scrollView.contentView.bounds.width)
      if column.width != width {
        column.width = width
        return true
      }
      return false
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

    private func refreshVisibleRows() {
      guard
        let tableView,
        let scrollView,
        let columnIndex = tableView.tableColumns.indices.first
      else {
        return
      }
      let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
      guard visibleRows.location != NSNotFound, visibleRows.length > 0 else {
        return
      }
      let rowRange = visibleRows.location..<(visibleRows.location + visibleRows.length)
      for row in rowRange where rows.indices.contains(row) {
        let view = tableView.view(
          atColumn: columnIndex,
          row: row,
          makeIfNecessary: false
        )
        (view as? SessionTimelineTableCellView)?.update(
          row: rows[row],
          actionHandler: actionHandler
        )
      }
    }

    private func invalidateVisibleRowHeights() {
      guard let tableView, let scrollView else {
        return
      }
      let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
      guard visibleRows.location != NSNotFound, visibleRows.length > 0 else {
        return
      }
      let rowRange = visibleRows.location..<(visibleRows.location + visibleRows.length)
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
        viewportStatsChanged(stats)
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
