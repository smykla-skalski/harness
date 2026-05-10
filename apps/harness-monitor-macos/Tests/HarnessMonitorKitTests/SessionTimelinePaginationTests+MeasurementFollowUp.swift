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

  @Test("Measuring rows above the viewport preserves the visible anchor")
  @MainActor
  func measuringRowsAboveViewportPreservesVisibleAnchor() async throws {
    let viewport = SessionTimelineViewportModel()
    let coordinator = SessionTimelineTableView.Coordinator(
      viewport: viewport,
      scrollBoundaryChanged: { _, _ in }
    )
    defer { coordinator.cancelMeasurement(reason: "test") }

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 945, height: 260))
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

    var rows = makeTimelineRows(count: 12)
    rows[0] = makeCustomTimelineRow(
      id: rows[0].id,
      title: "Expanded above viewport",
      detail: String(repeating: "Measured height must expand above the viewport. ", count: 80)
    )
    coordinator.update(
      rows: rows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(scrollView: scrollView, columnWidth: 945, fontScale: 1)
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let targetY = tableView.rect(ofRow: 5).minY + 8
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    let anchorBefore = try #require(coordinator.currentVisibleAnchor())
    #expect(anchorBefore.rowID == rows[5].id)

    await coordinator.runMeasurementTask(
      outstanding: [0],
      snapshot: rows,
      columnWidth: 945,
      generation: 1,
      totalOutstanding: 1
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    let anchorAfter = try #require(coordinator.currentVisibleAnchor())
    let measuredRow = try #require(coordinator.rowHeightCache[rows[0].id])
    let estimatedHeight = SessionTimelineTableMetrics.estimatedHeight(for: rows[0])

    #expect(measuredRow.isMeasured)
    #expect(abs(measuredRow.height - estimatedHeight) > 1)
    #expect(anchorAfter.rowID == anchorBefore.rowID)
    #expect(abs(anchorAfter.offsetY - anchorBefore.offsetY) < 1)
  }

  @Test("Stale width measurement exits before laying out hosted rows")
  @MainActor
  func staleWidthMeasurementExitsBeforeLayingOutHostedRows() async throws {
    let viewport = SessionTimelineViewportModel()
    let coordinator = SessionTimelineTableView.Coordinator(
      viewport: viewport,
      scrollBoundaryChanged: { _, _ in }
    )
    defer { coordinator.cancelMeasurement(reason: "test") }

    let rows = makeTimelineRows(count: 4)
    coordinator.rows = rows
    coordinator.lastColumnWidth = 945

    await coordinator.runMeasurementTask(
      outstanding: Array(rows.indices),
      snapshot: rows,
      columnWidth: 800,
      generation: 1,
      totalOutstanding: rows.count
    )

    #expect(coordinator.rowHeightCache.isEmpty)
    #expect(coordinator.measurementTask == nil)
  }
}
