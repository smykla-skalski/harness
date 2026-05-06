import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("SessionTimeline cursor navigation")
struct SessionTimelineNavigationScrollTests {
  @Test("Coordinator measurement uses the current font scale")
  @MainActor
  func coordinatorMeasurementUsesCurrentFontScale() {
    let acknowledgedSummary =
      "sig-20260504124537520229000 acknowledged by gemini-20260504124513402981000: Expired"
    let row = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: "session-1",
        entries: [
          makeTimelineEntry(
            kind: "signal_acknowledged",
            agentID: "gemini-20260504124513402981000",
            summary: acknowledgedSummary
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
      onSignalTap: nil,
      scrollCommand: nil,
      request: .init(
        scrollView: scrollView,
        columnWidth: 945,
        fontScale: 1.3
      )
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

  @Test("Latest normalization only corrects minor top drift")
  func latestNormalizationOnlyCorrectsMinorTopDrift() {
    #expect(
      SessionTimelineTableMetrics.shouldNormalizeLatestViewport(
        visibleMinY: SessionTimelineTableMetrics.pinnedLatestDriftTolerance + 12,
        firstVisibleRowIndex: 0
      )
    )
    #expect(
      !SessionTimelineTableMetrics.shouldNormalizeLatestViewport(
        visibleMinY: 40,
        firstVisibleRowIndex: 0
      )
    )
    #expect(
      !SessionTimelineTableMetrics.shouldNormalizeLatestViewport(
        visibleMinY: SessionTimelineTableMetrics.pinnedLatestDriftTolerance + 12,
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
      generation: 1,
      baselineWindowStart: initialNavigation.windowStart
    )
    let newerPending = SessionTimelinePendingNavigation(
      action: .newer,
      request: newerRequest,
      sessionID: "sess-pagination",
      generation: 2,
      baselineWindowStart: initialNavigation.windowStart
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
      generation: 1,
      baselineWindowStart: 6
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

}
