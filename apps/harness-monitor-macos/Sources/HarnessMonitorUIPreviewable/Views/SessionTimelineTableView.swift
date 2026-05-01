import AppKit
import HarnessMonitorKit
import SwiftUI

struct SessionTimelineTableViewportStats: Equatable, Sendable {
  let visibleRowCount: Int
  let renderedRowCount: Int

  static func initial(
    estimatedVisibleRows: Int,
    totalRows: Int
  ) -> Self {
    let count = min(max(estimatedVisibleRows, 0), max(totalRows, 0))
    return Self(visibleRowCount: count, renderedRowCount: count)
  }
}

enum SessionTimelineTableMetrics {
  static let baseRowHeight: CGFloat = 92
  private static let dayDividerHeight: CGFloat = 30
  private static let detailHeight: CGFloat = 20
  private static let actionHeight: CGFloat = 42

  static func height(for row: SessionTimelineRow) -> CGFloat {
    var height = baseRowHeight
    if row.dayDividerLabel != nil {
      height += dayDividerHeight
    }
    if row.node.detail != nil {
      height += detailHeight
    }
    if !row.node.actions.isEmpty {
      height += actionHeight
    }
    return height
  }
}

struct SessionTimelineTableView: NSViewRepresentable {
  let rows: [SessionTimelineRow]
  let scrollTargetID: String?
  let actionHandler: any DecisionActionHandler
  let viewportStatsChanged: (SessionTimelineTableViewportStats) -> Void
  let scrollBoundaryChanged: (SessionTimelineScrollBoundaryState, SessionTimelineScrollBoundaryState)
    -> Void

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
    tableView.intercellSpacing = NSSize(width: 0, height: HarnessMonitorTheme.itemSpacing)
    tableView.rowHeight = SessionTimelineTableMetrics.baseRowHeight
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
      scrollTargetID: scrollTargetID,
      scrollView: scrollView
    )
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    coordinator.stopObserving()
    (scrollView.documentView as? NSTableView)?.delegate = nil
    (scrollView.documentView as? NSTableView)?.dataSource = nil
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var viewportStatsChanged: (SessionTimelineTableViewportStats) -> Void
    var scrollBoundaryChanged:
      (SessionTimelineScrollBoundaryState, SessionTimelineScrollBoundaryState) -> Void

    private var rows: [SessionTimelineRow] = []
    private var actionHandler: any DecisionActionHandler = NullDecisionActionHandler()
    private weak var tableView: NSTableView?
    private weak var scrollView: NSScrollView?
    private var lastScrollTargetID: String?
    private var lastViewportStats: SessionTimelineTableViewportStats?
    private var lastBoundaryState = SessionTimelineScrollBoundaryState(
      visibleMinY: .greatestFiniteMagnitude,
      visibleMaxY: 0,
      contentHeight: .greatestFiniteMagnitude
    )

    init(
      viewportStatsChanged: @escaping (SessionTimelineTableViewportStats) -> Void,
      scrollBoundaryChanged: @escaping (
        SessionTimelineScrollBoundaryState,
        SessionTimelineScrollBoundaryState
      ) -> Void
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

    func stopObserving() {
      NotificationCenter.default.removeObserver(self)
    }

    func update(
      rows: [SessionTimelineRow],
      actionHandler: any DecisionActionHandler,
      scrollTargetID: String?,
      scrollView: NSScrollView
    ) {
      guard let tableView else {
        return
      }
      self.actionHandler = actionHandler
      let rowsChanged = self.rows != rows
      if rowsChanged {
        self.rows = rows
        tableView.reloadData()
      }
      resizeColumn(in: scrollView)
      if rowsChanged || scrollTargetID != lastScrollTargetID {
        scrollToTarget(scrollTargetID)
        lastScrollTargetID = scrollTargetID
      }
      publishViewportState()
    }

    func numberOfRows(in _: NSTableView) -> Int {
      rows.count
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

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard rows.indices.contains(row) else {
        return SessionTimelineTableMetrics.baseRowHeight
      }
      return SessionTimelineTableMetrics.height(for: rows[row])
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
      false
    }

    @objc private func contentBoundsDidChange(_: Notification) {
      publishViewportState()
    }

    private func resizeColumn(in scrollView: NSScrollView) {
      guard let tableView, let column = tableView.tableColumns.first else {
        return
      }
      let width = max(1, scrollView.contentView.bounds.width)
      if column.width != width {
        column.width = width
      }
    }

    private func scrollToTarget(_ rowID: String?) {
      guard let rowID,
        let tableView,
        let scrollView,
        let index = rows.firstIndex(where: { $0.id == rowID })
      else {
        return
      }
      tableView.layoutSubtreeIfNeeded()
      let rowRect = tableView.rect(ofRow: index)
      let y = max(0, min(rowRect.minY, max(0, tableView.bounds.height - scrollView.contentSize.height)))
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func publishViewportState() {
      guard let tableView, let scrollView else {
        return
      }
      let visibleRect = scrollView.contentView.bounds
      let visibleRows = tableView.rows(in: visibleRect)
      let visibleRowCount = max(0, visibleRows.length)
      let stats = SessionTimelineTableViewportStats(
        visibleRowCount: visibleRowCount,
        renderedRowCount: visibleRowCount
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
      if boundaryState != lastBoundaryState {
        let oldValue = lastBoundaryState
        lastBoundaryState = boundaryState
        scrollBoundaryChanged(oldValue, boundaryState)
      }
    }
  }
}

private final class SessionTimelineTableCellView: NSTableCellView {
  static let columnIdentifier = NSUserInterfaceItemIdentifier("session-timeline-column")
  static let cellIdentifier = NSUserInterfaceItemIdentifier("session-timeline-cell")

  private let hostingView = NSHostingView(rootView: SessionTimelineHostedRow.empty)

  init() {
    super.init(frame: .zero)
    identifier = Self.cellIdentifier
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(row: SessionTimelineRow, actionHandler: any DecisionActionHandler) {
    hostingView.rootView = SessionTimelineHostedRow(row: row, actionHandler: actionHandler)
  }
}

private struct SessionTimelineHostedRow: View {
  let row: SessionTimelineRow?
  let actionHandler: any DecisionActionHandler

  static var empty: Self {
    Self(row: nil, actionHandler: NullDecisionActionHandler())
  }

  var body: some View {
    if let row {
      ZStack(alignment: .topLeading) {
        Rectangle()
          .fill(HarnessMonitorTheme.controlBorder.opacity(0.55))
          .frame(width: 2)
          .padding(.top, HarnessMonitorTheme.spacingSM)
          .offset(x: SessionTimelineLayout.railLineOffset - 1)
          .accessibilityHidden(true)

        SessionTimelineNodeCluster(row: row, actionHandler: actionHandler)
          .padding(.trailing, HarnessMonitorTheme.spacingXS)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    } else {
      Color.clear
    }
  }
}
