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
        == TimelineWindowRequest(
          scope: .summary,
          limit: SessionTimelineWindowNavigation.defaultLimit,
          before: oldestCursor
        )
    )
    #expect(
      navigation.request(for: .latest)
        == .latest(limit: SessionTimelineWindowNavigation.defaultLimit)
    )
    #expect(
      navigation.request(for: .newer)
        == TimelineWindowRequest(
          scope: .summary,
          limit: SessionTimelineWindowNavigation.defaultLimit,
          after: newestCursor
        )
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
    #expect(
      navigation.request(for: .latest)
        == .latest(limit: SessionTimelineWindowNavigation.defaultLimit)
    )
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

  @Test("Scroll boundary state ignores reverse motion inside the bottom edge zone")
  func scrollBoundaryStateIgnoresReverseMotionInsideTheBottomEdgeZone() {
    let deeperBottomEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 275,
      visibleMaxY: 832,
      contentHeight: 1_000
    )
    let reversedBottomEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 246,
      visibleMaxY: 790,
      contentHeight: 1_000
    )
    let reboundBottomEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 275,
      visibleMaxY: 832,
      contentHeight: 1_000
    )

    #expect(!reversedBottomEntry.enteredBottomEdge(from: deeperBottomEntry))
    #expect(!reversedBottomEntry.shouldTrack(from: deeperBottomEntry))
    #expect(!reboundBottomEntry.enteredBottomEdge(from: deeperBottomEntry))
  }

  @Test("Scroll boundary state ignores reverse motion inside the top edge zone")
  func scrollBoundaryStateIgnoresReverseMotionInsideTheTopEdgeZone() {
    let deeperTopEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 32,
      visibleMaxY: 470,
      contentHeight: 1_000
    )
    let reversedTopEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 70,
      visibleMaxY: 508,
      contentHeight: 1_000
    )
    let reboundTopEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 32,
      visibleMaxY: 470,
      contentHeight: 1_000
    )

    #expect(!reversedTopEntry.enteredTopEdge(from: deeperTopEntry))
    #expect(!reversedTopEntry.shouldTrack(from: deeperTopEntry))
    #expect(!reboundTopEntry.enteredTopEdge(from: deeperTopEntry))
  }

  @Test("Scroll edge loading chooses an atomic buffer chunk")
  func scrollEdgeLoadingChoosesAnAtomicBufferChunk() {
    let entries = makeTimelineEntries(count: 12)
    let navigation = SessionTimelineWindowNavigation(
      timeline: entries,
      timelineWindow: makeWindow(
        entries: entries,
        windowStart: 0,
        windowEnd: 12,
        hasOlder: true,
        hasNewer: false,
        totalCount: 80
      ),
      isLoading: false
    )
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

    let limit = SessionTimelineEdgeLoadPolicy.limit(
      for: .older,
      context: SessionTimelineEdgeLoadContext(
        navigation: navigation,
        visibleRowCount: 6,
        fallbackVisibleRowCount: 6
      ),
      from: outsideBottom,
      to: firstBottomEntry
    )

    #expect(limit == 1)
  }

  @Test("Scroll edge loading scales with fast edge movement")
  func scrollEdgeLoadingScalesWithFastEdgeMovement() {
    let entries = makeTimelineEntries(count: 22)
    let navigation = SessionTimelineWindowNavigation(
      timeline: entries,
      timelineWindow: makeWindow(
        entries: entries,
        windowStart: 0,
        windowEnd: 22,
        hasOlder: true,
        hasNewer: false,
        totalCount: 30
      ),
      isLoading: false
    )
    let firstBottomEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 250,
      visibleMaxY: 800,
      contentHeight: 1_000
    )
    let fastBottomEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 470,
      visibleMaxY: 1_000,
      contentHeight: 1_000
    )

    let limit = SessionTimelineEdgeLoadPolicy.limit(
      for: .older,
      context: SessionTimelineEdgeLoadContext(
        navigation: navigation,
        visibleRowCount: 6,
        fallbackVisibleRowCount: 6
      ),
      from: firstBottomEntry,
      to: fastBottomEntry
    )

    #expect(limit == 3)
  }

  @Test("Scroll edge loading does not use viewport capacity as an edge page")
  func scrollEdgeLoadingDoesNotUseViewportCapacityAsAnEdgePage() {
    let entries = makeTimelineEntries(count: 32)
    let navigation = SessionTimelineWindowNavigation(
      timeline: entries,
      timelineWindow: makeWindow(
        entries: entries,
        windowStart: 0,
        windowEnd: 32,
        hasOlder: true,
        hasNewer: false,
        totalCount: 160
      ),
      isLoading: false
    )
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

    let limit = SessionTimelineEdgeLoadPolicy.limit(
      for: .older,
      context: SessionTimelineEdgeLoadContext(
        navigation: navigation,
        visibleRowCount: 6,
        viewportRowCapacity: 30,
        fallbackVisibleRowCount: 6
      ),
      from: outsideBottom,
      to: firstBottomEntry
    )

    #expect(limit == 1)
  }

  @Test("Pending scroll edge load retries only after the window advances")
  func pendingScrollEdgeLoadRetriesOnlyAfterTheWindowAdvances() {
    let initialEntries = makeTimelineEntries(count: 12)
    let initialNavigation = SessionTimelineWindowNavigation(
      timeline: initialEntries,
      timelineWindow: makeWindow(
        entries: initialEntries,
        windowStart: 0,
        windowEnd: 12,
        hasOlder: true,
        hasNewer: false,
        totalCount: 80
      ),
      isLoading: false
    )
    let pending = SessionTimelinePendingEdgeLoad(
      sessionID: "sess-pagination",
      action: .older,
      baselineWindowStart: initialNavigation.windowStart,
      baselineWindowEnd: initialNavigation.windowEnd
    )
    let unchangedNavigation = SessionTimelineWindowNavigation(
      timeline: initialEntries,
      timelineWindow: makeWindow(
        entries: initialEntries,
        windowStart: 0,
        windowEnd: 12,
        hasOlder: true,
        hasNewer: false,
        totalCount: 80
      ),
      isLoading: false
    )
    let advancedEntries = makeTimelineEntries(count: 22)
    let advancedNavigation = SessionTimelineWindowNavigation(
      timeline: advancedEntries,
      timelineWindow: makeWindow(
        entries: advancedEntries,
        windowStart: 0,
        windowEnd: 22,
        hasOlder: true,
        hasNewer: false,
        totalCount: 80
      ),
      isLoading: false
    )

    #expect(!pending.didAdvance(sessionID: "other-session", navigation: advancedNavigation))
    #expect(!pending.didAdvance(sessionID: "sess-pagination", navigation: unchangedNavigation))
    #expect(
      pending.isWaitingForFreshPresentation(
        sessionID: "sess-pagination",
        navigation: unchangedNavigation
      )
    )
    #expect(pending.didAdvance(sessionID: "sess-pagination", navigation: advancedNavigation))
  }

  @Test("Table row metrics reserve space for rich timeline rows")
  func tableRowMetricsReserveSpaceForRichTimelineRows() {
    let rows = makeTimelineRows(count: 13)
    let plainRow = rows[1]
    let detailedRow = rows[2]
    let dayDividerRow = rows[12]

    #expect(
      SessionTimelineTableMetrics.estimatedHeight(for: plainRow)
        >= SessionTimelineSectionPresentation.rowHeightEstimate
    )
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

}
