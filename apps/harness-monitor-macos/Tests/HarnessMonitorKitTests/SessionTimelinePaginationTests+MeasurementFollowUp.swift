import AppKit
import CoreGraphics
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionTimelineNavigationTests {
  @Test("Completed measurement schedules another pass when visible rows remain unmeasured")
  @MainActor
  func completedMeasurementSchedulesAnotherPassWhenVisibleRowsRemainUnmeasured() async throws {
    let viewport = SessionTimelineViewportModel()
    let coordinator = SessionTimelineTableView.Coordinator(
      viewport: viewport,
      scrollBoundaryChanged: { _, _ in }
    )
    defer { coordinator.cancelMeasurement(reason: "test") }

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 945, height: 470))
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = false

    let tableView = NSTableView(frame: scrollView.bounds)
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.intercellSpacing = .zero
    tableView.usesAutomaticRowHeights = false

    let column = NSTableColumn(identifier: SessionTimelineTableCellView.columnIdentifier)
    column.width = 945
    tableView.addTableColumn(column)
    tableView.delegate = coordinator
    tableView.dataSource = coordinator
    scrollView.documentView = tableView
    scrollView.contentView.postsBoundsChangedNotifications = true
    coordinator.configure(tableView: tableView, scrollView: scrollView)

    let rows = (0..<8).map { index in
      makeCustomTimelineRow(id: "timeline-entry-follow-up-\(index)", title: "Stable row \(index)")
    }
    coordinator.update(
      rows: rows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(
        scrollView: scrollView,
        columnWidth: 945,
        fontScale: 1
      )
    )
    coordinator.cancelMeasurement(reason: "test")
    coordinator.rowHeightCache.removeAll()
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)

    let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
    try #require(visibleRows.location == 0)
    #expect(visibleRows.length > 4)

    await coordinator.runMeasurementTask(
      outstanding: Array(0..<4),
      snapshot: rows,
      columnWidth: 945,
      generation: 1,
      totalOutstanding: 4
    )

    #expect(coordinator.rowHeightCache[rows[0].id]?.isMeasured == true)
    #expect(coordinator.rowHeightCache[rows[4].id] == nil)
    #expect(coordinator.measurementTask != nil)
  }
}
