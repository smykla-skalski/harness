import AppKit
import HarnessMonitorKit
import SwiftUI

struct SessionTimelineTableViewportStats: Equatable, Sendable {
  let visibleRowCount: Int
  let renderedRowCount: Int
  let viewportRowCapacity: Int
  let anchorRowID: String?
  let firstVisibleEventOffset: Int?
  let lastVisibleEventOffset: Int?
  let firstVisibleMatchOffset: Int?
  let lastVisibleMatchOffset: Int?

  init(
    visibleRowCount: Int,
    renderedRowCount: Int,
    viewportRowCapacity: Int? = nil,
    anchorRowID: String?,
    firstVisibleEventOffset: Int? = nil,
    lastVisibleEventOffset: Int? = nil,
    firstVisibleMatchOffset: Int? = nil,
    lastVisibleMatchOffset: Int? = nil
  ) {
    self.visibleRowCount = visibleRowCount
    self.renderedRowCount = renderedRowCount
    self.viewportRowCapacity = max(visibleRowCount, viewportRowCapacity ?? visibleRowCount)
    self.anchorRowID = anchorRowID
    self.firstVisibleEventOffset = firstVisibleEventOffset
    self.lastVisibleEventOffset = lastVisibleEventOffset
    self.firstVisibleMatchOffset = firstVisibleMatchOffset
    self.lastVisibleMatchOffset = lastVisibleMatchOffset
  }

  static func initial(estimatedVisibleEvents: Int) -> Self {
    let count = max(estimatedVisibleEvents, 0)
    return Self(
      visibleRowCount: count,
      renderedRowCount: count,
      viewportRowCapacity: count,
      anchorRowID: nil,
      firstVisibleEventOffset: count == 0 ? nil : 0,
      lastVisibleEventOffset: count == 0 ? nil : count - 1,
      firstVisibleMatchOffset: count == 0 ? nil : 0,
      lastVisibleMatchOffset: count == 0 ? nil : count - 1
    )
  }
}

struct SessionTimelineScrollCommand: Equatable, Sendable {
  let targetID: String
  let generation: Int
}

typealias SessionTimelineScrollBoundaryHandler =
  (SessionTimelineScrollBoundaryState, SessionTimelineScrollBoundaryState) -> Void
typealias SessionTimelineViewportHandler = (SessionTimelineTableViewportStats) -> Void

struct SessionTimelineTableAnchor {
  let rowID: String
  let offsetY: CGFloat
}

struct SessionTimelineTableView: NSViewRepresentable {
  let columnWidth: CGFloat
  let rows: [SessionTimelineRow]
  let contentIdentity: SessionTimelineContentIdentity?
  let scrollCommand: SessionTimelineScrollCommand?
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let viewport: SessionTimelineViewportModel
  let viewportChanged: SessionTimelineViewportHandler
  let scrollBoundaryChanged: SessionTimelineScrollBoundaryHandler
  @Environment(\.fontScale)
  private var fontScale

  func makeCoordinator() -> Coordinator {
    Coordinator(
      viewport: viewport,
      viewportChanged: viewportChanged,
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
    context.coordinator.viewport = viewport
    context.coordinator.viewportChanged = viewportChanged
    context.coordinator.scrollBoundaryChanged = scrollBoundaryChanged
    context.coordinator.update(
      rows: rows,
      contentIdentity: contentIdentity,
      actionHandler: actionHandler,
      onSignalTap: onSignalTap,
      scrollCommand: scrollCommand,
      request: .init(
        scrollView: scrollView,
        columnWidth: columnWidth,
        fontScale: fontScale
      )
    )
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    coordinator.cancelMeasurement(reason: "dismantle")
    coordinator.persistHeightCache()
    (scrollView.documentView as? NSTableView)?.delegate = nil
    (scrollView.documentView as? NSTableView)?.dataSource = nil
  }
}
