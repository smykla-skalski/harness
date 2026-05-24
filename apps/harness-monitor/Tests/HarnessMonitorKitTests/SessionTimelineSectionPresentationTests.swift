import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("SessionTimelineSectionPresentation")
struct SessionTimelineSectionPresentationTests {
  @Test("Empty timeline with no window produces an empty-state presentation")
  func emptyTimelinePresentationShowsEmptyState() {
    let presentation = makePresentation(timeline: [], timelineWindow: nil, isLoading: false)

    #expect(presentation.navigation.totalCount == 0)
    #expect(presentation.navigation.loadedCount == 0)
    #expect(presentation.navigation.windowStart == 0)
    #expect(presentation.rows.isEmpty)
    #expect(presentation.showsEmptyState)
    #expect(!presentation.showsFilteredEmptyState)
    #expect(presentation.filterMatchCountForVisibilityStats == nil)
    #expect(presentation.hasLatestWindow)
  }

  @Test("Loading-with-no-rows hides the empty state until the response arrives")
  func loadingTimelinePresentationHidesEmptyState() {
    let presentation = makePresentation(timeline: [], timelineWindow: nil, isLoading: true)

    #expect(!presentation.showsEmptyState)
    #expect(presentation.navigation.isLoading)
  }

  @Test("Latest window reports windowStart=0 and matches total count")
  func latestWindowPresentationReportsCounts() {
    let timeline = timelineEntries(count: 12)
    let window = TimelineWindowResponse(
      revision: 1,
      totalCount: 12,
      windowStart: 0,
      windowEnd: 12,
      hasOlder: false,
      hasNewer: false,
      oldestCursor: cursor(for: timeline.last!),
      newestCursor: cursor(for: timeline.first!),
      entries: nil,
      unchanged: false
    )

    let presentation = makePresentation(
      timeline: timeline,
      timelineWindow: window,
      isLoading: false
    )

    #expect(presentation.navigation.totalCount == 12)
    #expect(presentation.navigation.loadedCount == 12)
    #expect(presentation.navigation.windowStart == 0)
    #expect(presentation.navigation.windowEnd == 12)
    #expect(!presentation.navigation.hasOlder)
    #expect(!presentation.navigation.hasNewer)
    #expect(presentation.rows.count == timeline.count)
    #expect(!presentation.showsEmptyState)
    #expect(presentation.hasLatestWindow)
  }

  @Test("Partial middle window reports windowStart > 0 with paging cursors")
  func partialMiddleWindowReportsCursors() {
    let timeline = timelineEntries(count: 10)
    let window = TimelineWindowResponse(
      revision: 1,
      totalCount: 40,
      windowStart: 15,
      windowEnd: 25,
      hasOlder: true,
      hasNewer: true,
      oldestCursor: cursor(for: timeline.last!),
      newestCursor: cursor(for: timeline.first!),
      entries: nil,
      unchanged: false
    )

    let presentation = makePresentation(
      timeline: timeline,
      timelineWindow: window,
      isLoading: false
    )

    #expect(presentation.navigation.totalCount == 40)
    #expect(presentation.navigation.loadedCount == 10)
    #expect(presentation.navigation.windowStart == 15)
    #expect(presentation.navigation.windowEnd == 25)
    #expect(presentation.navigation.hasOlder)
    #expect(presentation.navigation.hasNewer)
    #expect(!presentation.hasLatestWindow)
  }

  @Test("Row count equals filter snapshot row count")
  func rowCountMatchesFilterSnapshot() {
    let timeline = timelineEntries(count: 5)
    let presentation = makePresentation(timeline: timeline, timelineWindow: nil, isLoading: false)

    #expect(presentation.rows.count == presentation.filterSnapshot.rows.count)
  }

  @Test("Presentation cache reuses derived graph for stable inputs")
  func presentationCacheReusesDerivedGraphForStableInputs() {
    let cache = SessionTimelineSectionPresentationCache()
    let timeline = timelineEntries(count: 5)
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    let first = cache.presentation(
      .init(
        sessionID: "session-presentation-tests",
        timeline: timeline,
        timelineWindow: nil,
        decisions: [],
        signals: [],
        filters: SessionTimelineFilterState(),
        isTimelineLoading: false,
        dateTimeConfiguration: .default,
        now: now
      )
    )
    let second = cache.presentation(
      .init(
        sessionID: "session-presentation-tests",
        timeline: timeline,
        timelineWindow: nil,
        decisions: [],
        signals: [],
        filters: SessionTimelineFilterState(),
        isTimelineLoading: false,
        dateTimeConfiguration: .default,
        now: now.addingTimeInterval(30)
      )
    )

    #expect(cache.rebuildCount == 1)
    #expect(first.rows == second.rows)
  }

  @Test("Presentation cache rebuilds when filters change")
  func presentationCacheRebuildsWhenFiltersChange() {
    let cache = SessionTimelineSectionPresentationCache()
    let timeline = timelineEntries(count: 5)
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    _ = cache.presentation(
      .init(
        sessionID: "session-presentation-tests",
        timeline: timeline,
        timelineWindow: nil,
        decisions: [],
        signals: [],
        filters: SessionTimelineFilterState(),
        isTimelineLoading: false,
        dateTimeConfiguration: .default,
        now: now
      )
    )
    var filters = SessionTimelineFilterState()
    filters.query = "Presentation event 3"
    let filtered = cache.presentation(
      .init(
        sessionID: "session-presentation-tests",
        timeline: timeline,
        timelineWindow: nil,
        decisions: [],
        signals: [],
        filters: filters,
        isTimelineLoading: false,
        dateTimeConfiguration: .default,
        now: now
      )
    )

    #expect(cache.rebuildCount == 2)
    #expect(filtered.rows.count == 1)
  }

  private func makePresentation(
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    isLoading: Bool
  ) -> SessionTimelineSectionPresentation {
    SessionTimelineSectionPresentation(
      sessionID: "session-presentation-tests",
      timeline: timeline,
      timelineWindow: timelineWindow,
      decisions: [],
      signals: [],
      filters: SessionTimelineFilterState(),
      isTimelineLoading: isLoading,
      dateTimeConfiguration: .default
    )
  }

  private func timelineEntries(count: Int) -> [TimelineEntry] {
    (0..<count).map { index in
      TimelineEntry(
        entryId: "presentation-entry-\(index)",
        recordedAt: String(format: "2026-04-14T03:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: "session-presentation-tests",
        agentId: "agent-1",
        taskId: nil,
        summary: "Presentation event \(index)",
        payload: .object([:])
      )
    }
  }

  private func cursor(for entry: TimelineEntry) -> TimelineCursor {
    TimelineCursor(recordedAt: entry.recordedAt, entryId: entry.entryId)
  }
}
