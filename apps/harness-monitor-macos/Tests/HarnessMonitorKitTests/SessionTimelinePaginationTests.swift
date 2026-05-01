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

  @Test("Visibility status keeps visible and loaded counts stable")
  func visibilityStatusKeepsVisibleAndLoadedCountsStable() {
    let stats = SessionTimelineVisibilityStats(
      visibleRowCount: 6,
      renderedRowCount: 15,
      loadedEventCount: 24,
      totalEventCount: 80
    )

    #expect(stats.statusText == "Visible rows 6 | Loaded events 24/80")
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
}
