import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionTimelineNavigationTests {
  @Test("Timeline window budget grows with viewport capacity")
  func timelineWindowBudgetGrowsWithViewportCapacity() {
    #expect(
      SessionTimelineWindowBudget.limit(forViewportRowCapacity: 4)
        == SessionTimelineWindowNavigation.defaultLimit
    )
    #expect(
      SessionTimelineWindowBudget.limit(forViewportRowCapacity: 30)
        == 30 + SessionTimelineScrollBoundaryState.triggerBufferRowCount
    )
    #expect(
      SessionTimelineWindowBudget.limit(forViewportRowCapacity: 500)
        == SessionTimelineWindowBudget.maximumLimit
    )
  }

  @Test("Edge loading caps fast chunks before evicting the visible anchor")
  func edgeLoadingCapsFastChunksBeforeEvictingVisibleAnchor() {
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
    let firstBottomEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 250,
      visibleMaxY: 800,
      contentHeight: 1_000
    )
    let fastBottomEntry = SessionTimelineScrollBoundaryState(
      visibleMinY: 1_060,
      visibleMaxY: 1_200,
      contentHeight: 1_200
    )

    let limit = SessionTimelineEdgeLoadPolicy.limit(
      for: .older,
      context: SessionTimelineEdgeLoadContext(
        navigation: navigation,
        visibleRowCount: 6,
        viewportRowCapacity: 6,
        fallbackVisibleRowCount: 6,
        firstVisibleEventOffset: 4,
        lastVisibleEventOffset: 11,
        retainedWindowLimit: 12
      ),
      from: firstBottomEntry,
      to: fastBottomEntry
    )

    #expect(limit == 4)
  }
}
