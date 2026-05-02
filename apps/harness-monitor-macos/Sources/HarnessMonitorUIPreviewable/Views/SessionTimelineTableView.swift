import AppKit
import HarnessMonitorKit
import SwiftUI

struct SessionTimelineTableViewportStats: Equatable, Sendable {
  let visibleRowCount: Int
  let renderedRowCount: Int
  let anchorRowID: String?

  static func initial(
    estimatedVisibleRows: Int,
    totalRows: Int
  ) -> Self {
    let count = min(max(estimatedVisibleRows, 0), max(totalRows, 0))
    return Self(
      visibleRowCount: count,
      renderedRowCount: count,
      anchorRowID: nil
    )
  }
}

struct SessionTimelineScrollCommand: Equatable, Sendable {
  let targetID: String
  let generation: Int
}

typealias SessionTimelineScrollBoundaryHandler =
  (SessionTimelineScrollBoundaryState, SessionTimelineScrollBoundaryState) -> Void

struct SessionTimelineTableAnchor {
  let rowID: String
  let offsetY: CGFloat
}

struct SessionTimelineTableView: NSViewRepresentable {
  let columnWidth: CGFloat
  let rows: [SessionTimelineRow]
  let scrollCommand: SessionTimelineScrollCommand?
  let actionHandler: any DecisionActionHandler
  let viewportStatsChanged: (SessionTimelineTableViewportStats) -> Void
  let scrollBoundaryChanged: SessionTimelineScrollBoundaryHandler

  func makeCoordinator() -> Coordinator {
    Coordinator(
      viewportStatsChanged: viewportStatsChanged,
      scrollBoundaryChanged: scrollBoundaryChanged
    )
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = false
    scrollView.borderType = .noBorder

    let tableView = NSTableView()
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.gridStyleMask = []
    tableView.intercellSpacing = .zero
    tableView.usesAutomaticRowHeights = false
    tableView.selectionHighlightStyle = .none
    tableView.allowsEmptySelection = true
    tableView.allowsColumnSelection = false
    tableView.allowsColumnReordering = false
    tableView.allowsColumnResizing = false
    if #available(macOS 11.0, *) {
      tableView.style = .plain
    }

    let column = NSTableColumn(identifier: SessionTimelineTableCellView.columnIdentifier)
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.delegate = context.coordinator
    tableView.dataSource = context.coordinator

    scrollView.documentView = tableView
    scrollView.contentView.postsBoundsChangedNotifications = true
    context.coordinator.configure(tableView: tableView, scrollView: scrollView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.viewportStatsChanged = viewportStatsChanged
    context.coordinator.scrollBoundaryChanged = scrollBoundaryChanged
    context.coordinator.update(
      rows: rows,
      actionHandler: actionHandler,
      scrollCommand: scrollCommand,
      scrollView: scrollView,
      columnWidth: columnWidth
    )
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    (scrollView.documentView as? NSTableView)?.delegate = nil
    (scrollView.documentView as? NSTableView)?.dataSource = nil
  }
}
