import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("SessionTimeline cursor navigation")
struct SessionTimelineNavigationVisibilityTests {
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

    viewport.updatePresentationCounts(
      windowStart: 47,
      loaded: rows.count,
      total: 321,
      filteredMatchCount: nil
    )
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

  @Test("Presentation refresh does not reset an observed viewport anchor")
  @MainActor
  func presentationRefreshDoesNotResetObservedViewportAnchor() {
    let viewport = SessionTimelineViewportModel()
    viewport.updatePresentationCounts(
      windowStart: 0,
      loaded: 24,
      total: 46,
      filteredMatchCount: nil
    )
    viewport.recordViewportStats(
      SessionTimelineTableViewportStats(
        visibleRowCount: 5,
        renderedRowCount: 5,
        viewportRowCapacity: 5,
        anchorRowID: "timeline-entry-visible-12",
        firstVisibleEventOffset: 12,
        lastVisibleEventOffset: 16
      ),
      publishImmediately: true
    )

    #expect(viewport.visibleAnchorID == "timeline-entry-visible-12")
    #expect(viewport.visibilityStats.statusText == "Showing 13-17 of 46")

    viewport.updatePresentationCounts(
      windowStart: 0,
      loaded: 34,
      total: 46,
      filteredMatchCount: nil
    )
    viewport.recordInitialViewport(estimatedVisibleEvents: 6)

    #expect(viewport.visibleAnchorID == "timeline-entry-visible-12")
    #expect(viewport.currentVisibleAnchorID() == "timeline-entry-visible-12")
    #expect(viewport.visibilityStats.statusText == "Showing 13-17 of 46")
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
    let acknowledgedSummary =
      "sig-20260503204520733172000 acknowledged by copilot-20260503203910393668000: Expired"
    let signalRow = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: "session-1",
        entries: [
          makeTimelineEntry(
            kind: "signal_acknowledged",
            agentID: "copilot-20260503203910393668000",
            summary: acknowledgedSummary
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
  func timelineRowsUseConsistentBottomSpacingAcrossLayouts() throws {
    let rows = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: PreviewFixtures.summary.sessionId,
        entries: PreviewFixtures.signalSquishTimeline,
        decisions: []
      )
      .build(),
      configuration: .default
    )

    let livenessRow = try #require(rows.first { $0.node.sourceLabel == "liveness_synced" })
    let signalRow = try #require(rows.first { $0.node.sourceLabel == "signal_acknowledged" })
    let observeRow = try #require(rows.first { $0.node.sourceLabel == "observe_snapshot" })

    #expect(
      SessionTimelineTableMetrics.rowBottomPadding(for: livenessRow)
        == HarnessMonitorTheme.itemSpacing
    )
    #expect(
      SessionTimelineTableMetrics.rowBottomPadding(for: signalRow)
        == HarnessMonitorTheme.itemSpacing
    )
    #expect(
      SessionTimelineTableMetrics.rowBottomPadding(for: observeRow)
        == HarnessMonitorTheme.itemSpacing
    )
  }

  @Test("Simple liveness rows avoid inflated minimum-card padding")
  @MainActor
  func simpleLivenessRowsAvoidInflatedMinimumCardPadding() throws {
    let rows = SessionTimelineRow.rows(
      for: SessionTimelineNodeBuilder(
        sessionID: PreviewFixtures.summary.sessionId,
        entries: PreviewFixtures.signalSquishTimeline,
        decisions: []
      )
      .build(),
      configuration: .default
    )

    let livenessRow = try #require(rows.first { $0.node.sourceLabel == "liveness_synced" })
    let signalRow = try #require(rows.first { $0.node.sourceLabel == "signal_acknowledged" })

    let livenessHeight = SessionTimelineTableCellView.measuredHeight(
      for: livenessRow,
      columnWidth: 945
    )
    let signalHeight = SessionTimelineTableCellView.measuredHeight(
      for: signalRow,
      columnWidth: 945
    )

    #expect(livenessHeight < SessionTimelineTableMetrics.estimatedBaseRowHeight)
    #expect(signalHeight >= livenessHeight)
  }

  @Test("Agentless single-line wide rows do not reserve empty action spacing")
  @MainActor
  func agentlessSingleLineWideRowsDoNotReserveEmptyActionSpacing() throws {
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

    let observeRow = try #require(rows.first { $0.node.sourceLabel == "observe_snapshot" })
    let livenessRow = try #require(rows.first { $0.node.sourceLabel == "liveness_synced" })

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
      columnWidth: 320,
      fontScale: 1.0
    )
    let enlargedHeight = SessionTimelineTableCellView.measuredHeight(
      for: row,
      columnWidth: 320,
      fontScale: 1.3
    )

    #expect(enlargedHeight > defaultHeight)
  }

}
