import AppKit
import CoreGraphics
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionTimelineNavigationTests {
  @Test("Programmatic scroll to edges still publishes edge entries")
  @MainActor
  func programmaticScrollToEdgesStillPublishesEdgeEntries() async throws {
    let viewport = SessionTimelineViewportModel()
    var topEdgeEntryCount = 0
    var bottomEdgeEntryCount = 0
    let coordinator = SessionTimelineTableView.Coordinator(
      viewport: viewport,
      scrollBoundaryChanged: { oldValue, newValue in
        if newValue.enteredTopEdge(from: oldValue) {
          topEdgeEntryCount += 1
        }
        if newValue.enteredBottomEdge(from: oldValue) {
          bottomEdgeEntryCount += 1
        }
      }
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

    let rows = makeTimelineRows(count: 14)
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

    try #require(coordinator.scrollToTarget(rows.last!.id))
    await Task.yield()
    await Task.yield()

    #expect(bottomEdgeEntryCount == 1)

    try #require(coordinator.scrollToTarget(rows.first!.id))
    await Task.yield()
    await Task.yield()

    #expect(topEdgeEntryCount == 1)
  }
}
