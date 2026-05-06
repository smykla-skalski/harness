import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("SessionTimeline cursor navigation")
struct SessionTimelineNavigationTests {
  @Test("Navigation exposes cursor-backed requests and status text")
  func navigationExposesCursorBackedRequestsAndStatusText() throws {
    let entries = makeTimelineEntries(count: 6, startingAt: 6)
    let oldestCursor = TimelineCursor(
      recordedAt: entries.last!.recordedAt,
      entryId: entries.last!.entryId
    )
    let newestCursor = TimelineCursor(
      recordedAt: entries.first!.recordedAt,
      entryId: entries.first!.entryId
    )
    let window = TimelineWindowResponse(
      revision: 4,
      totalCount: 32,
      windowStart: 6,
      windowEnd: 12,
      hasOlder: true,
      hasNewer: true,
      oldestCursor: oldestCursor,
      newestCursor: newestCursor,
      entries: nil,
      unchanged: false
    )

    let navigation = SessionTimelineWindowNavigation(
      timeline: entries,
      timelineWindow: window,
      isLoading: false
    )

    #expect(navigation.statusText == "Earlier events")
    #expect(
      navigation.request(for: .older)
        == TimelineWindowRequest(scope: .summary, limit: 24, before: oldestCursor)
    )
    #expect(navigation.request(for: .latest) == .latest(limit: 24))
    #expect(
      navigation.request(for: .newer)
        == TimelineWindowRequest(scope: .summary, limit: 24, after: newestCursor)
    )
  }

  @Test("Navigation disables unavailable older and newer directions")
  func navigationDisablesUnavailableOlderAndNewerDirections() {
    let entries = makeTimelineEntries(count: 4)
    let window = TimelineWindowResponse.fallbackMetadata(for: entries)
    let navigation = SessionTimelineWindowNavigation(
      timeline: entries,
      timelineWindow: window,
      isLoading: false
    )

    #expect(navigation.statusText == "Latest events")
    #expect(navigation.request(for: .older) == nil)
    #expect(navigation.request(for: .newer) == nil)
    #expect(navigation.request(for: .latest) == .latest(limit: 24))
  }

  @Test("Scroll boundary state enters bottom edge repeatedly as scrolling advances")
  func scrollBoundaryStateEntersBottomEdgeRepeatedlyAsScrollingAdvances() {
    let outsideBottom = SessionTimelineScrollBoundaryState(
      visibleMinY: 200,
      visibleMaxY: 760,
      contentHeight: 1_000
    )
    let firstBottomEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 250,
      visibleMaxY: 800,
      contentHeight: 1_000
    )
    let advancedBottomEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 275,
      visibleMaxY: 832,
      contentHeight: 1_000
    )

    #expect(firstBottomEntry.enteredBottomEdge(from: outsideBottom))
    #expect(!firstBottomEntry.enteredBottomEdge(from: firstBottomEntry))
    #expect(advancedBottomEntry.enteredBottomEdge(from: firstBottomEntry))
  }

  @Test("Table row metrics reserve space for rich timeline rows")
  func tableRowMetricsReserveSpaceForRichTimelineRows() {
    let rows = makeTimelineRows(count: 13)
    let plainRow = rows[1]
    let detailedRow = rows[2]
    let dayDividerRow = rows[12]

    #expect(SessionTimelineTableMetrics.estimatedHeight(for: plainRow) >= 92)
    #expect(SessionTimelineTableMetrics.estimatedHeight(for: detailedRow) > 92)
    #expect(
      SessionTimelineTableMetrics.estimatedHeight(for: dayDividerRow)
        > SessionTimelineTableMetrics.estimatedHeight(for: detailedRow)
    )
  }

  @Test("Table row measurement uses visible clip width when scrollers shrink content")
  func tableRowMeasurementUsesVisibleClipWidthWhenScrollersShrinkContent() {
    #expect(
      SessionTimelineTableMetrics.resolvedColumnWidth(
        proposedWidth: 960,
        visibleContentWidth: 945
      ) == 945
    )
    #expect(
      SessionTimelineTableMetrics.resolvedColumnWidth(
        proposedWidth: 960,
        visibleContentWidth: 0
      ) == 960
    )
  }

  @Test("Connector visibility omits rail stubs for the first and last rows")
  func connectorVisibilityOmitsRailStubsForTheFirstAndLastRows() {
    let only = SessionTimelineTableMetrics.connectorVisibility(rowIndex: 0, rowCount: 1)
    let first = SessionTimelineTableMetrics.connectorVisibility(rowIndex: 0, rowCount: 3)
    let middle = SessionTimelineTableMetrics.connectorVisibility(rowIndex: 1, rowCount: 3)
    let last = SessionTimelineTableMetrics.connectorVisibility(rowIndex: 2, rowCount: 3)

    #expect(only.showsConnectorAbove == false)
    #expect(only.showsConnectorBelow == false)
    #expect(first.showsConnectorAbove == false)
    #expect(first.showsConnectorBelow)
    #expect(middle.showsConnectorAbove)
    #expect(middle.showsConnectorBelow)
    #expect(last.showsConnectorAbove)
    #expect(last.showsConnectorBelow == false)
  }

  @Test("Pinned latest timeline keeps prepended rows visible without shifting viewport")
  @MainActor
  func pinnedLatestTimelineKeepsPrependedRowsVisibleWithoutShiftingViewport() async {
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
      request: .init(
        scrollView: scrollView,
        columnWidth: 945,
        fontScale: 1
      )
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    coordinator.publishViewportState()

    let newTopRow = SessionTimelineRow(
      node: SessionTimelineNode(
        identity: .entry("timeline-entry-newest"),
        kind: .event,
        timestamp: Date(timeIntervalSince1970: 1_900_000_100),
        rawTimestamp: nil,
        sourceLabel: "worker-pagination",
        title: "Newest timeline entry",
        detail: nil,
        eventTone: .info,
        decision: nil
      ),
      dayDividerLabel: nil,
      timestampLabel: "10:00:59",
      accessibilityTimestampLabel: "14 Apr 10:00:59",
      accessibilityLabel: "Newest timeline entry"
    )
    let updatedRows = [newTopRow] + initialRows

    coordinator.update(
      rows: updatedRows,
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
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    #expect(scrollView.contentView.bounds.minY == 0)
    let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
    #expect(coordinator.anchorRowID(for: visibleRows) == newTopRow.id)

    await Task.yield()
    await Task.yield()
    #expect(viewport.visibleAnchorID == newTopRow.id)
  }

  @Test("Timeline table measurement uses synchronous mode only for preview launches")
  func timelineTableMeasurementUsesSynchronousModeOnlyForPreviewLaunches() {
    #expect(
      SessionTimelineTableMeasurementMode.resolve(
        environment: [HarnessMonitorLaunchMode.xcodePreviewEnvironmentKey: "1"]
      ) == .synchronous
    )
    #expect(
      SessionTimelineTableMeasurementMode.resolve(environment: [:]) == .incremental
    )
    #expect(
      SessionTimelineTableMeasurementMode.resolve(
        environment: [
          HarnessMonitorLaunchMode.environmentKey: HarnessMonitorLaunchMode.live.rawValue,
          HarnessMonitorLaunchMode.xcodePreviewEnvironmentKey: "1",
        ]
      ) == .incremental
    )
  }

  @Test("Provisional cached row heights still require real measurement")
  @MainActor
  func provisionalCachedRowHeightsStillRequireRealMeasurement() {
    let provisional = CachedRowHeight(width: 945, height: 120, isMeasured: false)
    let measured = CachedRowHeight(width: 945, height: 120, isMeasured: true)

    #expect(
      provisional.requiresMeasurement(
        for: 945,
        tolerance: SessionTimelineTableView.Coordinator.widthEqualityTolerance
      )
    )
    #expect(
      !measured.requiresMeasurement(
        for: 945,
        tolerance: SessionTimelineTableView.Coordinator.widthEqualityTolerance
      )
    )
    #expect(
      measured.requiresMeasurement(
        for: 920,
        tolerance: SessionTimelineTableView.Coordinator.widthEqualityTolerance
      )
    )
  }

  @Test("Viewport publish schedules measurement for visible unmeasured rows")
  @MainActor
  func viewportPublishSchedulesMeasurementForVisibleUnmeasuredRows() {
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
      request: .init(
        scrollView: scrollView,
        columnWidth: 945,
        fontScale: 1
      )
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)

    coordinator.rowHeightCache = [
      initialRows[0].id: CachedRowHeight(
        width: 945,
        height: SessionTimelineTableMetrics.estimatedHeight(for: initialRows[0]),
        isMeasured: false
      )
    ]

    coordinator.publishViewportState()

    #expect(coordinator.measurementTask != nil)
  }

  @Test("Minor width jitter preserves measured visible row heights")
  @MainActor
  func minorWidthJitterPreservesMeasuredVisibleRowHeights() {
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

    let rows = makeTimelineRows(count: 8)
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
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let preservedRow = rows[0]
    let measuredHeight = tableView.rect(ofRow: 0).height
    coordinator.rowHeightCache = [
      preservedRow.id: CachedRowHeight(
        width: 945,
        height: measuredHeight,
        isMeasured: true
      )
    ]

    coordinator.update(
      rows: rows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(
        scrollView: scrollView,
        columnWidth: 945.25,
        fontScale: 1
      )
    )

    #expect(coordinator.rowHeightCache[preservedRow.id]?.isMeasured == true)
    #expect(coordinator.rowHeightCache[preservedRow.id]?.height == measuredHeight)
    #expect(coordinator.measurementTask == nil)
  }

  @Test("Prepended updates do not carry provisional visible heights forward")
  @MainActor
  func prependedUpdatesDoNotCarryProvisionalVisibleHeightsForward() {
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
      request: .init(
        scrollView: scrollView,
        columnWidth: 945,
        fontScale: 1
      )
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let provisionalRow = initialRows[0]
    coordinator.rowHeightCache = [
      provisionalRow.id: CachedRowHeight(
        width: 945,
        height: SessionTimelineTableMetrics.estimatedHeight(for: provisionalRow),
        isMeasured: false
      )
    ]

    let newTopRow = SessionTimelineRow(
      node: SessionTimelineNode(
        identity: .entry("timeline-entry-jitter-newest"),
        kind: .event,
        timestamp: Date(timeIntervalSince1970: 1_900_000_100),
        rawTimestamp: nil,
        sourceLabel: "worker-pagination",
        title: "Newest timeline entry",
        detail: nil,
        eventTone: .info,
        decision: nil
      ),
      dayDividerLabel: nil,
      timestampLabel: "10:00:59",
      accessibilityTimestampLabel: "14 Apr 10:00:59",
      accessibilityLabel: "Newest timeline entry"
    )

    coordinator.update(
      rows: [newTopRow] + initialRows,
      actionHandler: NullDecisionActionHandler(),
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(
        scrollView: scrollView,
        columnWidth: 945,
        fontScale: 1
      )
    )

    #expect(coordinator.rowHeightCache[provisionalRow.id] == nil)
    #expect(coordinator.measurementTask != nil)
  }

}
