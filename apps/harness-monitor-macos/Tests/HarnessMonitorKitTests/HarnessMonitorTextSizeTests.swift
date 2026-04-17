import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("HarnessMonitorTextSize magnification index delta")
struct HarnessMonitorTextSizeTests {
  @Test("Pinch out above threshold increments index")
  func pinchOutAboveThreshold() {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 1.2, currentIndex: 3) == 1)
  }

  @Test("Pinch in above threshold decrements index")
  func pinchInAboveThreshold() {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 0.8, currentIndex: 3) == -1)
  }

  @Test("Magnification within threshold returns zero")
  func withinThresholdReturnsZero() {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 1.1, currentIndex: 3) == 0)
  }

  @Test("At or just inside threshold boundary returns zero")
  func atThresholdBoundaryReturnsZero() {
    // 1.15 is exactly at the positive boundary (change == 0.15, not > 0.15)
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 1.15, currentIndex: 3) == 0)
    // Use 0.86 to stay clearly inside the negative threshold (change = -0.14)
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 0.86, currentIndex: 3) == 0)
  }

  @Test("Just above threshold returns positive one")
  func justAboveThresholdReturnsPositive() {
    #expect(
      HarnessMonitorTextSize.indexDelta(forMagnification: 1.15 + 0.01, currentIndex: 3) == 1)
  }

  @Test("Just below negative threshold returns negative one")
  func justBelowNegativeThresholdReturnsNegative() {
    #expect(
      HarnessMonitorTextSize.indexDelta(forMagnification: 0.85 - 0.01, currentIndex: 3) == -1)
  }

  @Test("At max index returns zero even with large magnification")
  func atMaxIndexReturnsZero() {
    let maxIndex = HarnessMonitorTextSize.scales.count - 1
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 2.0, currentIndex: maxIndex) == 0)
  }

  @Test("At min index returns zero even with small magnification")
  func atMinIndexReturnsZero() {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 0.5, currentIndex: 0) == 0)
  }

  @Test("Custom threshold parameter")
  func customThreshold() {
    #expect(
      HarnessMonitorTextSize.indexDelta(
        forMagnification: 1.05, currentIndex: 3, threshold: 0.04) == 1)
    #expect(
      HarnessMonitorTextSize.indexDelta(
        forMagnification: 1.05, currentIndex: 3, threshold: 0.1) == 0)
  }

  @Test("Pinch out increments across all non-max indices", arguments: 0..<6)
  func pinchOutIncrementsAtValidIndices(index: Int) {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 1.3, currentIndex: index) == 1)
  }

  @Test("Pinch in decrements across all non-min indices", arguments: 1...6)
  func pinchInDecrementsAtValidIndices(index: Int) {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 0.6, currentIndex: index) == -1)
  }

  @Test("No change when magnification is exactly 1.0")
  func noChangeAtExactlyOne() {
    #expect(HarnessMonitorTextSize.indexDelta(forMagnification: 1.0, currentIndex: 3) == 0)
  }
}

@Suite("SessionTimelinePagination page adjustment")
struct SessionTimelinePaginationTests {
  @Test("Adjusted page returns nil when the clamped page is unchanged")
  func adjustedPageReturnsNilWhenUnchanged() {
    #expect(
      SessionTimelinePagination.adjustedPage(
        currentPage: 0,
        itemCount: 24,
        pageSize: SessionTimelinePageSize.defaultSize.rawValue
      ) == nil
    )
  }

  @Test("Adjusted page returns corrected value when the current page becomes out of range")
  func adjustedPageReturnsCorrectedValueWhenOutOfRange() {
    #expect(
      SessionTimelinePagination.adjustedPage(
        currentPage: 3,
        itemCount: 18,
        pageSize: SessionTimelinePageSize.defaultSize.rawValue
      ) == 1
    )
  }

  @Test("Timeline growth does not request page reconciliation")
  func timelineGrowthDoesNotRequestPageReconciliation() {
    #expect(
      SessionTimelinePagination.adjustedPageAfterTimelineCountChange(
        currentPage: 3,
        oldItemCount: 20,
        newItemCount: 45,
        pageSize: SessionTimelinePageSize.defaultSize.rawValue
      ) == nil
    )
  }

  @Test("Presentation uses authoritative total count for range and page count")
  func presentationUsesAuthoritativeTotalCount() {
    let timeline = makeTimelineEntries(count: 10)
    let presentation = SessionTimelinePresentation(
      timeline: timeline,
      timelineWindow: makeTimelineWindow(totalCount: 42, loadedCount: 10),
      currentPage: 1,
      pageSize: SessionTimelinePageSize.ten.rawValue,
      isLoading: true
    )

    #expect(presentation.pageCount == 5)
    #expect(presentation.rangeText == "Showing 11-20 of 42")
    #expect(presentation.entries.isEmpty)
    #expect(presentation.placeholderCount == 10)
  }

  @Test("Presentation keeps requested page changes when only the first window is loaded")
  func presentationKeepsRequestedPageChangesWhenOnlyFirstWindowIsLoaded() {
    let presentation = SessionTimelinePresentation(
      timeline: makeTimelineEntries(count: 10),
      timelineWindow: makeTimelineWindow(totalCount: 42, loadedCount: 10),
      currentPage: 0,
      pageSize: SessionTimelinePageSize.ten.rawValue,
      isLoading: false
    )

    #expect(presentation.interactivePage(forRequestedPage: 1) == 1)
    #expect(presentation.interactivePage(forRequestedPage: 9) == 4)
  }

  @Test("Presentation fills only the unresolved slots with placeholders")
  func presentationFillsOnlyUnresolvedSlotsWithPlaceholders() {
    let timeline = makeTimelineEntries(count: 10)
    let presentation = SessionTimelinePresentation(
      timeline: timeline,
      timelineWindow: makeTimelineWindow(totalCount: 42, loadedCount: 10),
      currentPage: 0,
      pageSize: SessionTimelinePageSize.fifteen.rawValue,
      isLoading: true
    )

    #expect(presentation.rangeText == "Showing 1-15 of 42")
    #expect(presentation.entries.count == 10)
    #expect(presentation.placeholderCount == 5)
  }

  @Test("Presentation renders every loaded entry when metadata matches loaded count")
  func presentationRendersEveryLoadedEntryWhenMetadataMatchesLoadedCount() {
    let timeline = makeTimelineEntries(count: 3)
    let presentation = SessionTimelinePresentation(
      timeline: timeline,
      timelineWindow: makeTimelineWindow(totalCount: 3, loadedCount: 3),
      currentPage: 0,
      pageSize: SessionTimelinePageSize.ten.rawValue,
      isLoading: false
    )

    #expect(presentation.entries.count == 3)
    #expect(presentation.entries.map(\.entryId) == timeline.map(\.entryId))
    #expect(presentation.rangeText == "Showing 1-3 of 3")
    #expect(presentation.placeholderCount == 0)
  }

  @Test("Presentation keeps header and rendered rows in lockstep when not loading")
  func presentationKeepsHeaderAndRenderedRowsInLockstepWhenNotLoading() {
    // Regression guard: metadata claims 3 events but the timeline array arrived empty.
    // The header must not advertise "Showing 1-3 of 3" while zero rows render.
    let presentation = SessionTimelinePresentation(
      timeline: [],
      timelineWindow: makeTimelineWindow(totalCount: 3, loadedCount: 0),
      currentPage: 0,
      pageSize: SessionTimelinePageSize.ten.rawValue,
      isLoading: false
    )

    #expect(presentation.entries.isEmpty)
    #expect(presentation.placeholderCount == 0)
    #expect(presentation.rangeText == "Showing 0-0 of 3")
    #expect(
      presentation.needsRefresh,
      "stale window with zero loaded entries must ask the view to reload"
    )
  }

  @Test("Presentation does not request a refresh while the fetch is in flight")
  func presentationDoesNotRequestRefreshWhileLoading() {
    let presentation = SessionTimelinePresentation(
      timeline: [],
      timelineWindow: makeTimelineWindow(totalCount: 3, loadedCount: 0),
      currentPage: 0,
      pageSize: SessionTimelinePageSize.ten.rawValue,
      isLoading: true
    )

    #expect(!presentation.needsRefresh)
  }

  @Test("Presentation does not request a refresh when entries are visible")
  func presentationDoesNotRequestRefreshWhenEntriesAreVisible() {
    let timeline = makeTimelineEntries(count: 3)
    let presentation = SessionTimelinePresentation(
      timeline: timeline,
      timelineWindow: makeTimelineWindow(totalCount: 3, loadedCount: 3),
      currentPage: 0,
      pageSize: SessionTimelinePageSize.ten.rawValue,
      isLoading: false
    )

    #expect(!presentation.needsRefresh)
  }

  @Test("Presentation does not request a refresh when no entries are expected")
  func presentationDoesNotRequestRefreshWhenNoEntriesAreExpected() {
    let presentation = SessionTimelinePresentation(
      timeline: [],
      timelineWindow: nil,
      currentPage: 0,
      pageSize: SessionTimelinePageSize.ten.rawValue,
      isLoading: false
    )

    #expect(!presentation.needsRefresh)
  }

  @Test("Timeline content identity changes when the selected session changes")
  func timelineContentIdentityChangesWhenSessionChanges() {
    let primary = SessionTimelineContentIdentity(
      sessionID: "sess-primary"
    )
    let secondary = SessionTimelineContentIdentity(
      sessionID: "sess-secondary"
    )

    #expect(primary != secondary)
  }

  @Test("Timeline content identity stays stable across pagination changes")
  func timelineContentIdentityStaysStableAcrossPaginationChanges() {
    let firstPage = SessionTimelineContentIdentity(sessionID: "sess-primary")
    let laterPage = SessionTimelineContentIdentity(sessionID: "sess-primary")

    #expect(firstPage == laterPage)
  }

  private func makeTimelineEntries(count: Int) -> [TimelineEntry] {
    (0..<count).map { index in
      TimelineEntry(
        entryId: "timeline-entry-\(index)",
        recordedAt: String(format: "2026-04-14T10:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: "sess-pagination",
        agentId: "worker-pagination",
        taskId: nil,
        summary: "Timeline entry \(index)",
        payload: .object([:])
      )
    }
  }

  private func makeTimelineWindow(totalCount: Int, loadedCount: Int) -> TimelineWindowResponse {
    TimelineWindowResponse(
      revision: 7,
      totalCount: totalCount,
      windowStart: 0,
      windowEnd: loadedCount,
      hasOlder: loadedCount < totalCount,
      hasNewer: false,
      oldestCursor: nil,
      newestCursor: nil,
      entries: nil,
      unchanged: false
    )
  }
}

@Suite("SessionTimeline placeholder shimmer")
struct SessionTimelinePlaceholderShimmerTests {
  @Test("Shared shimmer animates only when unresolved placeholders are visible")
  func sharedShimmerAnimatesOnlyWhenNeeded() {
    #expect(
      SessionTimelinePlaceholderShimmer.shouldAnimate(
        reduceMotion: false,
        placeholderCount: 4
      )
    )
    #expect(
      SessionTimelinePlaceholderShimmer.shouldAnimate(
        reduceMotion: true,
        placeholderCount: 4
      ) == false
    )
    #expect(
      SessionTimelinePlaceholderShimmer.shouldAnimate(
        reduceMotion: false,
        placeholderCount: 0
      ) == false
    )
  }

  @Test("Shared shimmer phase stays in the expected horizontal travel range")
  func sharedShimmerPhaseStaysInExpectedRange() {
    let cycleDuration = SessionTimelinePlaceholderShimmer.cycleDuration
    let phaseAtStart = SessionTimelinePlaceholderShimmer.phase(
      at: Date(timeIntervalSinceReferenceDate: 0)
    )
    let phaseMidCycle = SessionTimelinePlaceholderShimmer.phase(
      at: Date(timeIntervalSinceReferenceDate: cycleDuration / 2)
    )
    let phaseAtWrap = SessionTimelinePlaceholderShimmer.phase(
      at: Date(timeIntervalSinceReferenceDate: cycleDuration)
    )

    #expect(phaseAtStart == -0.6)
    #expect(phaseMidCycle == 0.6)
    #expect(phaseAtWrap == -0.6)
  }
}
