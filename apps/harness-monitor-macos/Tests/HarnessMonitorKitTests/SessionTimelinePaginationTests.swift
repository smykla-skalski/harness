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

    #expect(navigation.statusText == "Showing 7-12 of 32")
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

    #expect(navigation.statusText == "Latest 4 of 4")
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

  @Test("Visibility stats count measured visible rows and preserve fallback during geometry gaps")
  func visibilityStatsCountMeasuredVisibleRowsAndPreserveFallbackDuringGeometryGaps() {
    let rowIDs = ["row-1", "row-2", "row-3"]
    let visible = SessionTimelineVisibilityStats.visibleRowCount(
      rowIDs: rowIDs,
      rowFrames: [
        "row-1": CGRect(x: 0, y: 0, width: 100, height: 80),
        "row-2": CGRect(x: 0, y: 96, width: 100, height: 132),
        "row-3": CGRect(x: 0, y: 244, width: 100, height: 64),
      ],
      visibleRect: CGRect(x: 0, y: 90, width: 400, height: 160),
      fallbackVisibleRowCount: 3
    )
    let fallback = SessionTimelineVisibilityStats.visibleRowCount(
      rowIDs: rowIDs,
      rowFrames: [:],
      visibleRect: CGRect(x: 0, y: 600, width: 400, height: 160),
      fallbackVisibleRowCount: 2
    )

    #expect(visible == 2)
    #expect(fallback == 2)
  }

  @Test("Virtualized layout renders a bounded top window instead of every loaded row")
  func virtualizedLayoutRendersBoundedTopWindow() {
    let rows = makeTimelineRows(count: 32)
    let layout = SessionTimelineVirtualizedLayout(
      rows: rows,
      rowHeights: rowHeights(for: rows, height: 74),
      scrollMetrics: SessionTimelineScrollMetrics(
        contentOffsetY: 0,
        viewportHeight: 470,
        visibleRect: CGRect(x: 0, y: 0, width: 800, height: 470)
      ),
      fallbackViewportHeight: 470,
      pinnedRowID: nil
    )

    #expect(layout.totalRowCount == 32)
    #expect(layout.renderedRowCount < rows.count)
    #expect(layout.rows.first?.id == rows.first?.id)
    #expect(layout.topSpacerHeight == 0)
    #expect(layout.bottomSpacerHeight > 0)
  }

  @Test("Virtualized layout follows fast fling offsets with leading and trailing spacers")
  func virtualizedLayoutFollowsFastFlingOffsets() {
    let rows = makeTimelineRows(count: 40)
    let heights = Dictionary(
      uniqueKeysWithValues: rows.enumerated().map { index, row in
        (row.id, CGFloat(index.isMultiple(of: 3) ? 132 : 74))
      }
    )
    let layout = SessionTimelineVirtualizedLayout(
      rows: rows,
      rowHeights: heights,
      scrollMetrics: SessionTimelineScrollMetrics(
        contentOffsetY: 1_500,
        viewportHeight: 420,
        visibleRect: CGRect(x: 0, y: 1_500, width: 800, height: 420)
      ),
      fallbackViewportHeight: 420,
      pinnedRowID: nil
    )

    #expect(layout.renderedRowCount < rows.count)
    #expect(layout.topSpacerHeight > 0)
    #expect(layout.bottomSpacerHeight > 0)
    #expect(layout.rows.first?.id != rows.first?.id)
    #expect(layout.rows.last?.id != rows.last?.id)
  }

  @Test(
    "Virtualized layout includes a pending programmatic scroll target without rendering all rows"
  )
  func virtualizedLayoutIncludesPendingProgrammaticScrollTarget() {
    let rows = makeTimelineRows(count: 36)
    let pinnedRow = rows[28]
    let layout = SessionTimelineVirtualizedLayout(
      rows: rows,
      rowHeights: rowHeights(for: rows, height: 74),
      scrollMetrics: SessionTimelineScrollMetrics(
        contentOffsetY: 0,
        viewportHeight: 420,
        visibleRect: CGRect(x: 0, y: 0, width: 800, height: 420)
      ),
      fallbackViewportHeight: 420,
      pinnedRowID: pinnedRow.id
    )

    #expect(layout.renderedRowIDs.contains(pinnedRow.id))
    #expect(layout.renderedRowCount < rows.count)
    #expect(layout.topSpacerHeight > 0)
  }

  @Test("Visibility status reports rendered rows separately from loaded events")
  func visibilityStatusReportsRenderedRowsSeparatelyFromLoadedEvents() {
    let stats = SessionTimelineVisibilityStats(
      visibleRowCount: 6,
      renderedRowCount: 15,
      loadedEventCount: 24,
      totalEventCount: 80
    )

    #expect(stats.statusText == "Visible rows 6 | Rendered rows 15 | Loaded events 24/80")
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

  private func rowHeights(
    for rows: [SessionTimelineRow],
    height: CGFloat
  ) -> [String: CGFloat] {
    Dictionary(uniqueKeysWithValues: rows.map { ($0.id, height) })
  }
}
