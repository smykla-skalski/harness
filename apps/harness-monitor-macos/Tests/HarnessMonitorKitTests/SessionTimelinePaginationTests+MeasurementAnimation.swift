import AppKit
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionTimelineNavigationTests {
  @Test("Reused measured row heights remain measured after row updates")
  @MainActor
  func reusedMeasuredRowHeightsRemainMeasuredAfterRowUpdates() {
    let viewport = SessionTimelineViewportModel()
    let coordinator = SessionTimelineTableView.Coordinator(
      viewport: viewport,
      scrollBoundaryChanged: { _, _ in }
    )
    defer { coordinator.cancelMeasurement(reason: "test") }

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 945, height: 320))
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

    let initialRows = makeTimelineRows(count: 8)
    coordinator.update(
      rows: initialRows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(scrollView: scrollView, columnWidth: 945, fontScale: 1)
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let reusedRow = initialRows[0]
    let measuredHeight = tableView.rect(ofRow: 0).height + 180
    coordinator.rowHeightCache = [
      reusedRow.id: CachedRowHeight(
        width: 945,
        height: measuredHeight,
        isMeasured: true
      )
    ]

    coordinator.update(
      rows: [makeCustomTimelineRow(id: "timeline-entry-new-top", title: "New top row")]
        + initialRows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(scrollView: scrollView, columnWidth: 945, fontScale: 1)
    )

    #expect(coordinator.rowHeightCache[reusedRow.id]?.isMeasured == true)
    #expect(coordinator.rowHeightCache[reusedRow.id]?.height == measuredHeight)
    #expect(!coordinator.visibleRowsNeedMeasurement(columnWidth: 945))
  }
}
