import AppKit
import CoreGraphics
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionTimelineNavigationTests {
  @Test("Rolling older row replacement preserves scroll offset")
  @MainActor
  func rollingOlderRowReplacementPreservesScrollOffset() throws {
    let fixture = makeRollingViewportFixture()
    defer { fixture.coordinator.cancelMeasurement(reason: "test") }

    let rows = makeTimelineRows(count: 14)
    updateRollingViewport(fixture, rows: Array(rows[0..<12]))
    let baselineY = try scrollRollingViewport(fixture, toPreferredY: 320)

    updateRollingViewport(fixture, rows: Array(rows[2..<14]))

    #expect(abs(fixture.scrollView.contentView.bounds.minY - baselineY) < 0.5)
  }

  @Test("Rolling newer row replacement preserves scroll offset")
  @MainActor
  func rollingNewerRowReplacementPreservesScrollOffset() throws {
    let fixture = makeRollingViewportFixture()
    defer { fixture.coordinator.cancelMeasurement(reason: "test") }

    let rows = makeTimelineRows(count: 16)
    updateRollingViewport(fixture, rows: Array(rows[4..<16]))
    let baselineY = try scrollRollingViewport(fixture, toPreferredY: 120)

    updateRollingViewport(fixture, rows: Array(rows[0..<12]))

    #expect(abs(fixture.scrollView.contentView.bounds.minY - baselineY) < 0.5)
  }

  @Test("Rolling replacement keeps reused visible row heights measured")
  @MainActor
  func rollingReplacementKeepsReusedVisibleRowHeightsMeasured() throws {
    let fixture = makeRollingViewportFixture()
    defer { fixture.coordinator.cancelMeasurement(reason: "test") }

    let rows = makeTimelineRows(count: 14)
    let initialRows = Array(rows[0..<12])
    updateRollingViewport(fixture, rows: initialRows)
    fixture.coordinator.measureSynchronously(
      outstanding: Array(initialRows.indices),
      snapshot: initialRows,
      columnWidth: 945,
      generation: 1,
      totalOutstanding: initialRows.count
    )
    _ = try scrollRollingViewport(fixture, toPreferredY: 320)
    let anchorBefore = try #require(fixture.coordinator.currentVisibleAnchor())

    updateRollingViewport(fixture, rows: Array(rows[2..<14]))

    let cachedAnchorHeight = try #require(
      fixture.coordinator.rowHeightCache[anchorBefore.rowID]
    )
    #expect(cachedAnchorHeight.isMeasured)
  }

  @Test("No-op visible measurement does not move the viewport")
  @MainActor
  func noOpVisibleMeasurementDoesNotMoveViewport() throws {
    let fixture = makeRollingViewportFixture()
    defer { fixture.coordinator.cancelMeasurement(reason: "test") }

    let rows = makeTimelineRows(count: 12)
    updateRollingViewport(fixture, rows: rows)
    let measuredHeights = rows.map {
      SessionTimelineTableCellView.measuredHeight(for: $0, columnWidth: 945)
    }
    for (index, row) in rows.enumerated() {
      fixture.coordinator.rowHeightCache[row.id] = CachedRowHeight(
        width: 945,
        height: measuredHeights[index],
        isMeasured: true
      )
    }
    fixture.tableView.noteHeightOfRows(
      withIndexesChanged: IndexSet(integersIn: rows.indices)
    )
    fixture.tableView.layoutSubtreeIfNeeded()
    fixture.scrollView.layoutSubtreeIfNeeded()

    let measuredRowIndex = 5
    fixture.coordinator.rowHeightCache[rows[measuredRowIndex].id] = CachedRowHeight(
      width: 945,
      height: measuredHeights[measuredRowIndex],
      isMeasured: false
    )
    let baselineY = try scrollRollingViewport(
      fixture,
      toPreferredY: fixture.tableView.rect(ofRow: measuredRowIndex).minY + 8
    )

    fixture.coordinator.measureSynchronously(
      outstanding: [measuredRowIndex],
      snapshot: rows,
      columnWidth: 945,
      generation: 2,
      totalOutstanding: 1
    )

    #expect(abs(fixture.scrollView.contentView.bounds.minY - baselineY) < 0.5)
    #expect(fixture.coordinator.measurementTask == nil)
    #expect(fixture.coordinator.rowHeightCache[rows[measuredRowIndex].id]?.isMeasured == true)
  }
}

private struct RollingViewportFixture {
  let coordinator: SessionTimelineTableView.Coordinator
  let scrollView: NSScrollView
  let tableView: NSTableView
}

@MainActor
private func makeRollingViewportFixture() -> RollingViewportFixture {
  let viewport = SessionTimelineViewportModel()
  let coordinator = SessionTimelineTableView.Coordinator(
    viewport: viewport,
    scrollBoundaryChanged: { _, _ in }
  )
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

  return RollingViewportFixture(
    coordinator: coordinator,
    scrollView: scrollView,
    tableView: tableView
  )
}

@MainActor
private func updateRollingViewport(
  _ fixture: RollingViewportFixture,
  rows: [SessionTimelineRow]
) {
  fixture.coordinator.update(
    rows: rows,
    actionHandler: NullDecisionActionHandler(),
    onSignalTap: nil,
    scrollCommand: nil,
    request: .init(scrollView: fixture.scrollView, columnWidth: 945, fontScale: 1)
  )
  fixture.coordinator.cancelMeasurement(reason: "test")
  fixture.tableView.layoutSubtreeIfNeeded()
  fixture.scrollView.layoutSubtreeIfNeeded()
}

@MainActor
private func scrollRollingViewport(
  _ fixture: RollingViewportFixture,
  toPreferredY preferredY: CGFloat
) throws -> CGFloat {
  let maximumY = max(
    0,
    fixture.tableView.bounds.height - fixture.scrollView.contentSize.height
  )
  let baselineY = min(preferredY, maximumY)
  try #require(baselineY > 0)
  fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: baselineY))
  fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)
  fixture.coordinator.publishViewportState()
  return fixture.scrollView.contentView.bounds.minY
}
