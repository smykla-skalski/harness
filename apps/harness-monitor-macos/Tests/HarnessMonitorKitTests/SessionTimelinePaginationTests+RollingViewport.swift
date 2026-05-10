import AppKit
import CoreGraphics
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionTimelineNavigationTests {
  @Test("Rolling older row replacement preserves visible anchor")
  @MainActor
  func rollingOlderRowReplacementPreservesVisibleAnchor() throws {
    let fixture = makeRollingViewportFixture()
    defer { fixture.coordinator.cancelMeasurement(reason: "test") }

    let rows = makeTimelineRows(count: 14)
    updateRollingViewport(fixture, rows: Array(rows[0..<12]))
    _ = try scrollRollingViewport(fixture, toPreferredY: 320)
    let anchorBefore = try #require(fixture.coordinator.currentVisibleAnchor())

    updateRollingViewport(fixture, rows: Array(rows[2..<14]))

    let anchorAfter = try #require(fixture.coordinator.currentVisibleAnchor())
    #expect(anchorAfter.rowID == anchorBefore.rowID)
    #expect(abs(anchorAfter.offsetY - anchorBefore.offsetY) < 1)
  }

  @Test("Rolling newer row replacement preserves visible anchor")
  @MainActor
  func rollingNewerRowReplacementPreservesVisibleAnchor() throws {
    let fixture = makeRollingViewportFixture()
    defer { fixture.coordinator.cancelMeasurement(reason: "test") }

    let rows = makeTimelineRows(count: 16)
    updateRollingViewport(fixture, rows: Array(rows[4..<16]))
    _ = try scrollRollingViewport(fixture, toPreferredY: 120)
    let anchorBefore = try #require(fixture.coordinator.currentVisibleAnchor())

    updateRollingViewport(fixture, rows: Array(rows[0..<12]))

    let anchorAfter = try #require(fixture.coordinator.currentVisibleAnchor())
    #expect(anchorAfter.rowID == anchorBefore.rowID)
    #expect(abs(anchorAfter.offsetY - anchorBefore.offsetY) < 1)
  }

  @Test("Rolling newer replacement premeasures rows before the restored anchor")
  @MainActor
  func rollingNewerReplacementPremeasuresRowsBeforeRestoredAnchor() throws {
    let fixture = makeRollingViewportFixture()
    defer { fixture.coordinator.cancelMeasurement(reason: "test") }

    var rows = makeTimelineRows(count: 20)
    rows[0] = makeCustomTimelineRow(
      id: rows[0].id,
      title: "Tall inserted row",
      detail: String(repeating: "Preloaded row height must already be known. ", count: 20)
    )
    updateRollingViewport(fixture, rows: Array(rows[4..<20]))
    _ = try scrollRollingViewport(
      fixture,
      toPreferredY: fixture.tableView.rect(ofRow: 6).minY
    )
    let anchorBefore = try #require(fixture.coordinator.currentVisibleAnchor())

    updateRollingViewport(fixture, rows: Array(rows[0..<16]))

    let anchorAfter = try #require(fixture.coordinator.currentVisibleAnchor())
    #expect(anchorAfter.rowID == anchorBefore.rowID)
    for index in 0..<4 {
      let cachedHeight = try #require(fixture.coordinator.rowHeightCache[rows[index].id])
      #expect(cachedHeight.isMeasured)
      #expect(abs(fixture.tableView.rect(ofRow: index).height - cachedHeight.height) < 0.5)
    }
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

  @Test("Rolling replacement does not overwrite measured height from old row rect")
  @MainActor
  func rollingReplacementDoesNotOverwriteMeasuredHeightFromOldRowRect() throws {
    let fixture = makeRollingViewportFixture()
    defer { fixture.coordinator.cancelMeasurement(reason: "test") }

    let rows = makeTimelineRows(count: 14)
    updateRollingViewport(fixture, rows: Array(rows[0..<12]))
    _ = try scrollRollingViewport(
      fixture,
      toPreferredY: fixture.tableView.rect(ofRow: 4).minY
    )
    let preservedRow = rows[4]
    let preservedHeight: CGFloat = 222
    fixture.coordinator.rowHeightCache[preservedRow.id] = CachedRowHeight(
      width: 945,
      height: preservedHeight,
      isMeasured: true
    )

    updateRollingViewport(fixture, rows: Array(rows[2..<14]))

    #expect(fixture.coordinator.rowHeightCache[preservedRow.id]?.height == preservedHeight)
  }

  @Test("Programmatic anchor restore does not emit edge callbacks")
  @MainActor
  func programmaticAnchorRestoreDoesNotEmitEdgeCallbacks() async throws {
    var topEdgeEntryCount = 0
    let fixture = makeRollingViewportFixture { oldValue, newValue in
      if newValue.enteredTopEdge(from: oldValue) {
        topEdgeEntryCount += 1
      }
    }
    defer { fixture.coordinator.cancelMeasurement(reason: "test") }

    let rows = makeTimelineRows(count: 12)
    updateRollingViewport(fixture, rows: rows)
    _ = try scrollRollingViewport(fixture, toPreferredY: 420)
    topEdgeEntryCount = 0

    fixture.coordinator.restore(
      anchor: SessionTimelineTableAnchor(rowID: rows[0].id, offsetY: 0)
    )
    await Task.yield()
    await Task.yield()

    #expect(fixture.scrollView.contentView.bounds.minY <= 16)
    #expect(topEdgeEntryCount == 0)
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

  @Test("Live scroll still schedules visible row measurement")
  @MainActor
  func liveScrollStillSchedulesVisibleRowMeasurement() {
    let fixture = makeRollingViewportFixture()
    defer {
      fixture.coordinator.cancelMeasurement(reason: "test")
      fixture.coordinator.cancelLiveScrollTracking()
    }

    let rows = makeTimelineRows(count: 12)
    updateRollingViewport(fixture, rows: rows)
    fixture.coordinator.rowHeightCache.removeAll()
    fixture.coordinator.isViewportMoving = true

    fixture.coordinator.scheduleIncrementalMeasurement(columnWidth: 945)

    #expect(fixture.coordinator.measurementTask != nil)
  }

  @Test("Live scroll applies measured heights immediately")
  @MainActor
  func liveScrollAppliesMeasuredHeightsImmediately() throws {
    let fixture = makeRollingViewportFixture()
    defer {
      fixture.coordinator.cancelMeasurement(reason: "test")
      fixture.coordinator.cancelLiveScrollTracking()
    }

    var rows = makeTimelineRows(count: 8)
    rows[0] = makeCustomTimelineRow(
      id: rows[0].id,
      title: "Tall row",
      detail: String(repeating: "Measured row height must apply while scrolling. ", count: 30)
    )
    updateRollingViewport(fixture, rows: rows)
    fixture.coordinator.rowHeightCache.removeAll()
    fixture.coordinator.isViewportMoving = true

    fixture.coordinator.measureSynchronously(
      outstanding: [0],
      snapshot: rows,
      columnWidth: 945,
      generation: 1,
      totalOutstanding: 1
    )

    #expect(fixture.coordinator.rowHeightCache[rows[0].id]?.isMeasured == true)
    let cachedHeight = try #require(fixture.coordinator.rowHeightCache[rows[0].id]?.height)
    #expect(abs(fixture.tableView.rect(ofRow: 0).height - cachedHeight) < 0.5)
  }
}

private struct RollingViewportFixture {
  let coordinator: SessionTimelineTableView.Coordinator
  let scrollView: NSScrollView
  let tableView: NSTableView
}

@MainActor
private func makeRollingViewportFixture(
  scrollBoundaryChanged: @escaping SessionTimelineScrollBoundaryHandler = { _, _ in }
) -> RollingViewportFixture {
  let viewport = SessionTimelineViewportModel()
  let coordinator = SessionTimelineTableView.Coordinator(
    viewport: viewport,
    scrollBoundaryChanged: scrollBoundaryChanged
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
