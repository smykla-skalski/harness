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
      scrollCommand: nil,
      scrollView: scrollView,
      columnWidth: 945,
      fontScale: 1
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
      scrollCommand: nil,
      scrollView: scrollView,
      columnWidth: 945,
      fontScale: 1
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
      scrollCommand: nil,
      scrollView: scrollView,
      columnWidth: 945,
      fontScale: 1
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

  @Test("Viewport visibility stats track the visible event range while scrolling")
  @MainActor
  func viewportVisibilityStatsTrackVisibleEventRangeWhileScrolling() {
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

    let rows = (0..<24).map { index in
      makeCustomTimelineRow(
        id: "timeline-entry-visible-\(index)",
        title: "Visible row \(index)"
      )
    }
    coordinator.update(
      rows: rows,
      actionHandler: NullDecisionActionHandler(),
      scrollCommand: nil,
      scrollView: scrollView,
      columnWidth: 945,
      fontScale: 1
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    viewport.updatePresentationCounts(windowStart: 47, loaded: rows.count, total: 321)
    coordinator.publishViewportState()

    let topVisibleRows = tableView.rows(in: scrollView.contentView.bounds)
    let topStart = 47 + topVisibleRows.location + 1
    let topEnd = 47 + topVisibleRows.location + topVisibleRows.length
    #expect(viewport.visibilityStats.firstVisibleEventNumber == topStart)
    #expect(viewport.visibilityStats.lastVisibleEventNumber == topEnd)
    #expect(viewport.visibilityStats.statusText == "Showing \(topStart)-\(topEnd) of 321")

    let targetRowRect = tableView.rect(ofRow: 8)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetRowRect.minY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    coordinator.publishViewportState()

    let scrolledVisibleRows = tableView.rows(in: scrollView.contentView.bounds)
    let scrolledStart = 47 + scrolledVisibleRows.location + 1
    let scrolledEnd = 47 + scrolledVisibleRows.location + scrolledVisibleRows.length
    #expect(viewport.visibilityStats.firstVisibleEventNumber == scrolledStart)
    #expect(viewport.visibilityStats.lastVisibleEventNumber == scrolledEnd)
    #expect(
      viewport.visibilityStats.statusText
        == "Showing \(scrolledStart)-\(scrolledEnd) of 321"
    )
  }

  @Test("Height cache invalidates changed carry-over rows and font scale changes")
  func heightCacheInvalidatesChangedCarryOverRowsAndFontScaleChanges() {
    let unchangedRow = makeCustomTimelineRow(
      id: "timeline-entry-unchanged",
      title: "Stable row"
    )
    let originalRow = makeCustomTimelineRow(
      id: "timeline-entry-stable",
      title: "Expandable row"
    )
    let changedRow = makeCustomTimelineRow(
      id: "timeline-entry-stable",
      title: "Expandable row",
      detail: "Expanded detail that changes the row layout"
    )

    let previous = SessionTimelineTableSnapshot(rows: [unchangedRow, originalRow])
    let next = SessionTimelineTableSnapshot(rows: [unchangedRow, changedRow])

    #expect(
      next.heightCacheInvalidationIDs(comparedTo: previous, fontScaleChanged: false)
        == Set([changedRow.id])
    )
    #expect(
      next.heightCacheInvalidationIDs(comparedTo: previous, fontScaleChanged: true)
        == Set([unchangedRow.id, changedRow.id])
    )
  }

  @Test("Signal timeline rows prefer compact layout while liveness rows stay wide")
  @MainActor
  func signalTimelineRowsPreferCompactLayoutWhileLivenessRowsStayWide() {
    let signalRow = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: "session-1",
        entries: [
          makeTimelineEntry(
            kind: "signal_acknowledged",
            agentID: "copilot-20260503203910393668000",
            summary: "sig-20260503204520733172000 acknowledged by copilot-20260503203910393668000: Expired"
          )
        ],
        decisions: []
      )
      .build(),
      configuration: .default
    )[0]

    let livenessRow = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: "session-1",
        entries: [
          makeTimelineEntry(
            kind: "liveness_synced",
            agentID: "harness-app",
            summary: "Liveness sync: 0 disconnected, 1 idled"
          )
        ],
        decisions: []
      )
      .build(),
      configuration: .default
    )[0]

    #expect(SessionTimelineTableMetrics.prefersCompactLayout(for: signalRow))
    #expect(!SessionTimelineTableMetrics.prefersCompactLayout(for: livenessRow))
  }

  @Test("Timeline rows use consistent bottom spacing across layouts")
  @MainActor
  func timelineRowsUseConsistentBottomSpacingAcrossLayouts() {
    let rows = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: PreviewFixtures.summary.sessionId,
        entries: PreviewFixtures.signalSquishTimeline,
        decisions: []
      )
      .build(),
      configuration: .default
    )

    let livenessRow = try! #require(rows.first { $0.node.sourceLabel == "liveness_synced" })
    let signalRow = try! #require(rows.first { $0.node.sourceLabel == "signal_acknowledged" })
    let observeRow = try! #require(rows.first { $0.node.sourceLabel == "observe_snapshot" })

    #expect(SessionTimelineTableMetrics.rowBottomPadding(for: livenessRow) == HarnessMonitorTheme.itemSpacing)
    #expect(SessionTimelineTableMetrics.rowBottomPadding(for: signalRow) == HarnessMonitorTheme.itemSpacing)
    #expect(SessionTimelineTableMetrics.rowBottomPadding(for: observeRow) == HarnessMonitorTheme.itemSpacing)
  }

  @Test("Signal timeline rows keep minimum breathing room for compact and wide cards")
  @MainActor
  func signalTimelineRowsKeepMinimumBreathingRoomForCompactAndWideCards() {
    let rows = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: PreviewFixtures.summary.sessionId,
        entries: PreviewFixtures.signalSquishTimeline,
        decisions: []
      )
      .build(),
      configuration: .default
    )

    let livenessRow = try! #require(rows.first { $0.node.sourceLabel == "liveness_synced" })
    let signalRow = try! #require(rows.first { $0.node.sourceLabel == "signal_acknowledged" })

    let livenessHeight = SessionTimelineTableCellView.measuredHeight(
      for: livenessRow,
      columnWidth: 945
    )
    let signalHeight = SessionTimelineTableCellView.measuredHeight(
      for: signalRow,
      columnWidth: 945
    )

    #expect(livenessHeight >= SessionTimelineTableMetrics.minimumCardHeight(for: livenessRow))
    #expect(signalHeight >= SessionTimelineTableMetrics.minimumCardHeight(for: signalRow))
  }

  @Test("Agentless single-line wide rows do not reserve empty action spacing")
  @MainActor
  func agentlessSingleLineWideRowsDoNotReserveEmptyActionSpacing() {
    let rows = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: "session-1",
        entries: [
          TimelineEntry(
            entryId: "observe-snapshot",
            recordedAt: "2026-05-03T21:03:34Z",
            kind: "observe_snapshot",
            sessionId: "session-1",
            agentId: nil,
            taskId: nil,
            summary: "Observe scan: 0 open, 0 active workers, 0 muted codes",
            payload: .object([:])
          ),
          TimelineEntry(
            entryId: "liveness-synced",
            recordedAt: "2026-05-03T21:28:11Z",
            kind: "liveness_synced",
            sessionId: "session-1",
            agentId: "harness-app",
            taskId: nil,
            summary: "Liveness sync: 1 disconnected, 0 idled",
            payload: .object([:])
          ),
        ],
        decisions: []
      )
      .build(),
      configuration: .default
    )

    let observeRow = try! #require(rows.first { $0.node.sourceLabel == "observe_snapshot" })
    let livenessRow = try! #require(rows.first { $0.node.sourceLabel == "liveness_synced" })

    #expect(observeRow.node.detail == nil)
    #expect(observeRow.node.actions.isEmpty)

    let observeHeight = SessionTimelineTableCellView.measuredHeight(
      for: observeRow,
      columnWidth: 945
    )
    let livenessHeight = SessionTimelineTableCellView.measuredHeight(
      for: livenessRow,
      columnWidth: 945
    )

    #expect(observeHeight < livenessHeight)
  }

  @Test("Timeline row measurement responds to font scale changes")
  @MainActor
  func timelineRowMeasurementRespondsToFontScaleChanges() {
    let row = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: "session-1",
        entries: [
          TimelineEntry(
            entryId: "agent-joined",
            recordedAt: "2026-05-03T21:15:12Z",
            kind: "agent_joined",
            sessionId: "session-1",
            agentId: nil,
            taskId: nil,
            summary: "gemini-20260504124323411402000 joined as Leader (gemini)",
            payload: .object([:])
          )
        ],
        decisions: []
      )
      .build(),
      configuration: .default
    )[0]

    let defaultHeight = SessionTimelineTableCellView.measuredHeight(
      for: row,
      columnWidth: 945,
      fontScale: 1.0
    )
    let enlargedHeight = SessionTimelineTableCellView.measuredHeight(
      for: row,
      columnWidth: 945,
      fontScale: 1.3
    )

    #expect(enlargedHeight > defaultHeight)
  }

  @Test("Coordinator measurement uses the current font scale")
  @MainActor
  func coordinatorMeasurementUsesCurrentFontScale() {
    let row = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: "session-1",
        entries: [
          makeTimelineEntry(
            kind: "signal_acknowledged",
            agentID: "gemini-20260504124513402981000",
            summary: "sig-20260504124537520229000 acknowledged by gemini-20260504124513402981000: Expired"
          )
        ],
        decisions: []
      )
      .build(),
      configuration: .default
    )[0]

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

    coordinator.update(
      rows: [row],
      actionHandler: NullDecisionActionHandler(),
      scrollCommand: nil,
      scrollView: scrollView,
      columnWidth: 945,
      fontScale: 1.3
    )
    coordinator.cancelMeasurement(reason: "test")
    coordinator.rowHeightCache.removeAll()

    coordinator.measureSynchronously(
      outstanding: [0],
      snapshot: [row],
      columnWidth: 945,
      generation: 1,
      totalOutstanding: 1
    )

    let defaultHeight = SessionTimelineTableCellView.measuredHeight(
      for: row,
      columnWidth: 945,
      fontScale: 1.0
    )
    let enlargedHeight = SessionTimelineTableCellView.measuredHeight(
      for: row,
      columnWidth: 945,
      fontScale: 1.3
    )

    #expect(coordinator.rowHeightCache[row.id]?.height == enlargedHeight)
    #expect(enlargedHeight > defaultHeight)
  }

  @Test("Near-top viewport drift still auto-sticks to latest rows")
  func nearTopViewportDriftStillAutoSticksToLatestRows() {
    #expect(
      SessionTimelineTableMetrics.shouldStickToLatestOnRowsChange(
        visibleMinY: 0,
        firstVisibleRowIndex: 0
      )
    )
    #expect(
      SessionTimelineTableMetrics.shouldStickToLatestOnRowsChange(
        visibleMinY: SessionTimelineTableMetrics.pinnedLatestDriftTolerance - 1,
        firstVisibleRowIndex: 0
      )
    )
    #expect(
      !SessionTimelineTableMetrics.shouldStickToLatestOnRowsChange(
        visibleMinY: SessionTimelineTableMetrics.pinnedLatestDriftTolerance + 4,
        firstVisibleRowIndex: 0
      )
    )
    #expect(
      !SessionTimelineTableMetrics.shouldStickToLatestOnRowsChange(
        visibleMinY: 0,
        firstVisibleRowIndex: 1
      )
    )
  }

  @Test("Top visible first row normalizes back to latest after rows prepend")
  @MainActor
  func topVisibleFirstRowNormalizesBackToLatestAfterRowsPrepend() async {
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
      scrollCommand: nil,
      scrollView: scrollView,
      columnWidth: 945,
      fontScale: 1
    )
    coordinator.cancelMeasurement(reason: "test")
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    scrollView.contentView.scroll(
      to: NSPoint(x: 0, y: SessionTimelineTableMetrics.pinnedLatestDriftTolerance + 12)
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
    coordinator.publishViewportState()

    let newTopRow = SessionTimelineRow(
      node: SessionTimelineNode(
        identity: .entry("timeline-entry-newest-near-top"),
        kind: .event,
        timestamp: Date(timeIntervalSince1970: 1_900_000_100),
        rawTimestamp: nil,
        sourceLabel: "worker-pagination",
        title: "Newest near-top timeline entry",
        detail: nil,
        eventTone: .info,
        decision: nil
      ),
      dayDividerLabel: nil,
      timestampLabel: "10:00:59",
      accessibilityTimestampLabel: "14 Apr 10:00:59",
      accessibilityLabel: "Newest near-top timeline entry"
    )
    let updatedRows = [newTopRow] + initialRows

    coordinator.update(
      rows: updatedRows,
      actionHandler: NullDecisionActionHandler(),
      scrollCommand: nil,
      scrollView: scrollView,
      columnWidth: 945,
      fontScale: 1
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

  @Test("Table scroll restoration preserves anchor offset after rows insert above")
  func tableScrollRestorationPreservesAnchorOffsetAfterRowsInsertAbove() {
    let restoredY = SessionTimelineTableMetrics.restoredScrollY(
      rowMinY: 640,
      anchorOffsetY: 32,
      contentHeight: 2_400,
      viewportHeight: 470
    )
    let clampedY = SessionTimelineTableMetrics.restoredScrollY(
      rowMinY: 2_380,
      anchorOffsetY: 80,
      contentHeight: 2_400,
      viewportHeight: 470
    )

    #expect(restoredY == 672)
    #expect(clampedY == 1_930)
  }

  @Test("Table scroll restoration preserves anchor offset after rows are removed above")
  func tableScrollRestorationPreservesAnchorOffsetAfterRowsRemovedAbove() {
    let restoredY = SessionTimelineTableMetrics.restoredScrollY(
      rowMinY: 280,
      anchorOffsetY: 32,
      contentHeight: 1_700,
      viewportHeight: 470
    )
    let clampedTopY = SessionTimelineTableMetrics.restoredScrollY(
      rowMinY: -42,
      anchorOffsetY: 24,
      contentHeight: 1_700,
      viewportHeight: 470
    )

    #expect(restoredY == 312)
    #expect(clampedTopY == 0)
  }

  @Test("Pending navigation waits for matching loaded window and latest intent wins")
  func pendingNavigationWaitsForMatchingLoadedWindowAndLatestIntentWins() {
    let entries = makeTimelineEntries(count: 6, startingAt: 6)
    let initialNavigation = SessionTimelineWindowNavigation(
      timeline: entries,
      timelineWindow: makeWindow(
        entries: entries,
        windowStart: 6,
        windowEnd: 12,
        hasOlder: true,
        hasNewer: true
      ),
      isLoading: false
    )
    let olderRequest = initialNavigation.request(for: .older)!
    let newerRequest = initialNavigation.request(for: .newer)!
    let olderPending = SessionTimelinePendingNavigation(
      action: .older,
      request: olderRequest,
      sessionID: "sess-pagination",
      generation: 1
    )
    let newerPending = SessionTimelinePendingNavigation(
      action: .newer,
      request: newerRequest,
      sessionID: "sess-pagination",
      generation: 2
    )

    #expect(!olderPending.isSatisfied(sessionID: "other-session", navigation: initialNavigation))
    #expect(!olderPending.isSatisfied(sessionID: "sess-pagination", navigation: initialNavigation))
    #expect(!newerPending.isSatisfied(sessionID: "sess-pagination", navigation: initialNavigation))

    let olderLoadedEntries = makeTimelineEntries(count: 6, startingAt: 12)
    let olderLoadedNavigation = SessionTimelineWindowNavigation(
      timeline: olderLoadedEntries,
      timelineWindow: makeWindow(
        entries: olderLoadedEntries,
        windowStart: 12,
        windowEnd: 18,
        hasOlder: true,
        hasNewer: true
      ),
      isLoading: false
    )
    #expect(
      olderPending.isSatisfied(
        sessionID: "sess-pagination",
        navigation: olderLoadedNavigation
      )
    )
    #expect(
      !newerPending.isSatisfied(
        sessionID: "sess-pagination",
        navigation: olderLoadedNavigation
      )
    )
  }

  @Test("Pending latest navigation waits until latest window is loaded")
  func pendingLatestNavigationWaitsUntilLatestWindowIsLoaded() {
    let olderEntries = makeTimelineEntries(count: 6, startingAt: 6)
    let pending = SessionTimelinePendingNavigation(
      action: .latest,
      request: .latest(limit: SessionTimelineWindowNavigation.defaultLimit),
      sessionID: "sess-pagination",
      generation: 1
    )
    let olderNavigation = SessionTimelineWindowNavigation(
      timeline: olderEntries,
      timelineWindow: makeWindow(
        entries: olderEntries,
        windowStart: 6,
        windowEnd: 12,
        hasOlder: true,
        hasNewer: true
      ),
      isLoading: false
    )
    let latestEntries = makeTimelineEntries(count: 6)
    let latestNavigation = SessionTimelineWindowNavigation(
      timeline: latestEntries,
      timelineWindow: makeWindow(
        entries: latestEntries,
        windowStart: 0,
        windowEnd: 6,
        hasOlder: true,
        hasNewer: false
      ),
      isLoading: false
    )

    #expect(!pending.isSatisfied(sessionID: "sess-pagination", navigation: olderNavigation))
    #expect(pending.isSatisfied(sessionID: "sess-pagination", navigation: latestNavigation))
  }

  @Test("Visibility status shows the current visible event range")
  func visibilityStatusShowsTheCurrentVisibleEventRange() {
    let stats = SessionTimelineVisibilityStats(
      visibleRowCount: 6,
      renderedRowCount: 15,
      loadedEventCount: 24,
      totalEventCount: 321,
      firstVisibleEventNumber: 48,
      lastVisibleEventNumber: 56
    )

    #expect(stats.statusText == "Showing 48-56 of 321")
    #expect(stats.accessibilityStatusText == "Showing events 48 to 56 of 321")
  }

  @Test("Timeline content identity changes only across sessions")
  func timelineContentIdentityChangesOnlyAcrossSessions() {
    let primary = SessionTimelineContentIdentity(sessionID: "sess-primary")
    let sameSession = SessionTimelineContentIdentity(sessionID: "sess-primary")
    let secondary = SessionTimelineContentIdentity(sessionID: "sess-secondary")

    #expect(primary == sameSession)
    #expect(primary != secondary)
  }

  private func makeTimelineEntries(count: Int, startingAt startIndex: Int = 0) -> [TimelineEntry] {
    (0..<count).map { index in
      let entryIndex = startIndex + index
      return TimelineEntry(
        entryId: "timeline-entry-\(entryIndex)",
        recordedAt: String(format: "2026-04-14T10:%02d:00Z", 59 - entryIndex),
        kind: "task_checkpoint",
        sessionId: "sess-pagination",
        agentId: "worker-pagination",
        taskId: nil,
        summary: "Timeline entry \(entryIndex)",
        payload: .object([:])
      )
    }
  }

  private func makeTimelineEntry(
    kind: String,
    agentID: String,
    summary: String
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: "timeline-entry-\(kind)-\(agentID)",
      recordedAt: "2026-04-14T10:00:00Z",
      kind: kind,
      sessionId: "session-1",
      agentId: agentID,
      taskId: nil,
      summary: summary,
      payload: .object([:])
    )
  }

  private func makeTimelineRows(count: Int) -> [SessionTimelineRow] {
    (0..<count).map { index in
      let node = SessionTimelineNode(
        identity: .entry("timeline-entry-\(index)"),
        kind: .event,
        timestamp: Date(timeIntervalSince1970: TimeInterval(1_900_000_000 - index)),
        rawTimestamp: nil,
        sourceLabel: "worker-pagination",
        title: "Timeline entry \(index)",
        detail: index.isMultiple(of: 2) ? "Detailed event payload \(index)" : nil,
        eventTone: .info,
        decision: nil
      )
      return SessionTimelineRow(
        node: node,
        dayDividerLabel: index == 12 ? "14 Apr" : nil,
        timestampLabel: "10:\(String(format: "%02d", index)):00",
        accessibilityTimestampLabel: "14 Apr 10:\(String(format: "%02d", index)):00",
        accessibilityLabel: "Event \(index)"
      )
    }
  }

  private func makeWindow(
    entries: [TimelineEntry],
    windowStart: Int,
    windowEnd: Int,
    hasOlder: Bool,
    hasNewer: Bool
  ) -> TimelineWindowResponse {
    TimelineWindowResponse(
      revision: Int64(windowStart + windowEnd),
      totalCount: 32,
      windowStart: windowStart,
      windowEnd: windowEnd,
      hasOlder: hasOlder,
      hasNewer: hasNewer,
      oldestCursor: entries.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      newestCursor: entries.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      entries: nil,
      unchanged: false
    )
  }

  private func makeCustomTimelineRow(
    id: String,
    title: String,
    detail: String? = nil
  ) -> SessionTimelineRow {
    SessionTimelineRow(
      node: SessionTimelineNode(
        identity: .entry(id),
        kind: .event,
        timestamp: Date(timeIntervalSince1970: 1_900_000_000),
        rawTimestamp: nil,
        sourceLabel: "worker-pagination",
        title: title,
        detail: detail,
        eventTone: .info,
        decision: nil
      ),
      dayDividerLabel: nil,
      timestampLabel: "10:00:00",
      accessibilityTimestampLabel: "14 Apr 10:00:00",
      accessibilityLabel: title
    )
  }
}
