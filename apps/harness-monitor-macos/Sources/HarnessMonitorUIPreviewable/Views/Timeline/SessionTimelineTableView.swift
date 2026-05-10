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
  let virtualization: SessionTimelineTableVirtualization
  let contentIdentity: SessionTimelineContentIdentity?
  let horizontalContentInset: CGFloat
  let topScrollEdgeBlurHeight: CGFloat
  let bottomScrollEdgeBlurHeight: CGFloat
  let scrollCommand: SessionTimelineScrollCommand?
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let viewport: SessionTimelineViewportModel
  let viewportChanged: SessionTimelineViewportHandler
  let scrollBoundaryChanged: SessionTimelineScrollBoundaryHandler
  @Environment(\.fontScale)
  private var fontScale

  init(
    columnWidth: CGFloat,
    rows: [SessionTimelineRow],
    virtualization: SessionTimelineTableVirtualization,
    contentIdentity: SessionTimelineContentIdentity?,
    horizontalContentInset: CGFloat = 0,
    topScrollEdgeBlurHeight: CGFloat = 0,
    bottomScrollEdgeBlurHeight: CGFloat = 0,
    scrollCommand: SessionTimelineScrollCommand?,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)?,
    viewport: SessionTimelineViewportModel,
    viewportChanged: @escaping SessionTimelineViewportHandler,
    scrollBoundaryChanged: @escaping SessionTimelineScrollBoundaryHandler
  ) {
    self.columnWidth = columnWidth
    self.rows = rows
    self.virtualization = virtualization
    self.contentIdentity = contentIdentity
    self.horizontalContentInset = horizontalContentInset
    self.topScrollEdgeBlurHeight = topScrollEdgeBlurHeight
    self.bottomScrollEdgeBlurHeight = bottomScrollEdgeBlurHeight
    self.scrollCommand = scrollCommand
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.viewport = viewport
    self.viewportChanged = viewportChanged
    self.scrollBoundaryChanged = scrollBoundaryChanged
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      viewport: viewport,
      viewportChanged: viewportChanged,
      scrollBoundaryChanged: scrollBoundaryChanged
    )
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = SessionTimelineTableScrollView()
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

    let documentView = SessionTimelineTableDocumentView()
    documentView.addSubview(tableView)
    scrollView.documentView = documentView
    scrollView.installScrollEdgeEffectViews()
    scrollView.contentView.postsBoundsChangedNotifications = true
    context.coordinator.configure(
      tableView: tableView,
      scrollView: scrollView,
      documentView: documentView
    )
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    // Skip the viewport reassignment when the model reference matches.
    // Closures must be reassigned each body invocation because they
    // capture per-render presentation state; coordinator.update() does
    // its own change-detection and short-circuits when inputs match.
    if context.coordinator.viewport !== viewport {
      context.coordinator.viewport = viewport
    }
    if let scrollView = scrollView as? SessionTimelineTableScrollView {
      scrollView.updateScrollEdgeEffectHeights(
        top: topScrollEdgeBlurHeight,
        bottom: bottomScrollEdgeBlurHeight
      )
    }
    context.coordinator.viewportChanged = viewportChanged
    context.coordinator.scrollBoundaryChanged = scrollBoundaryChanged
    context.coordinator.update(
      rows: rows,
      virtualization: virtualization,
      contentIdentity: contentIdentity,
      actionHandler: actionHandler,
      onSignalTap: onSignalTap,
      scrollCommand: scrollCommand,
      request: .init(
        scrollView: scrollView,
        columnWidth: columnWidth,
        horizontalContentInset: horizontalContentInset,
        fontScale: fontScale
      )
    )
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    coordinator.cancelMeasurement(reason: "dismantle")
    coordinator.cancelLiveScrollTracking()
    coordinator.persistHeightCache()
    coordinator.tableView?.delegate = nil
    coordinator.tableView?.dataSource = nil
  }
}

extension SessionTimelineTableView: @MainActor Equatable {
  // Closures and the optional onSignalTap are intentionally excluded:
  // they get reassigned on every parent body invocation, but they are
  // method references on a stable view value, so their behavior depends
  // only on the inputs already compared here. Excluding them lets
  // .equatable() actually skip updateNSView when nothing meaningful
  // changed.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.columnWidth == rhs.columnWidth
      && lhs.horizontalContentInset == rhs.horizontalContentInset
      && lhs.topScrollEdgeBlurHeight == rhs.topScrollEdgeBlurHeight
      && lhs.bottomScrollEdgeBlurHeight == rhs.bottomScrollEdgeBlurHeight
      && lhs.contentIdentity == rhs.contentIdentity
      && lhs.scrollCommand == rhs.scrollCommand
      && lhs.virtualization == rhs.virtualization
      && lhs.viewport === rhs.viewport
      && ObjectIdentifier(lhs.actionHandler as AnyObject)
        == ObjectIdentifier(rhs.actionHandler as AnyObject)
      && rowsLookEqual(lhs: lhs.rows, rhs: rhs.rows)
  }

  private static func rowsLookEqual(
    lhs: [SessionTimelineRow],
    rhs: [SessionTimelineRow]
  ) -> Bool {
    lhs.count == rhs.count && lhs.first?.id == rhs.first?.id
      && lhs.last?.id == rhs.last?.id
  }
}
