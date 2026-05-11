import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("SessionTimelineCountSummary")
struct SessionTimelineCountSummaryTests {
  @Test("Zero total renders an empty status string")
  func zeroTotalRendersEmptyString() {
    let navigation = makeNavigation(timeline: [], window: nil)
    let text = SessionTimelineCountSummary.statusText(
      navigation: navigation,
      filterSummary: .empty,
      filterMatchCount: nil
    )

    #expect(text == "")
  }

  @Test("Fully loaded latest window renders an event count")
  func fullyLoadedLatestWindowRendersEventCount() {
    let timeline = makeTimeline(count: 200)
    let window = makeWindow(
      totalCount: 200,
      windowStart: 0,
      windowEnd: 200,
      hasOlder: false,
      hasNewer: false
    )
    let navigation = makeNavigation(timeline: timeline, window: window)

    let text = SessionTimelineCountSummary.statusText(
      navigation: navigation,
      filterSummary: .empty,
      filterMatchCount: nil
    )

    #expect(text == "200 events")
  }

  @Test("Single event renders the singular form")
  func singleEventRendersSingularForm() {
    let timeline = makeTimeline(count: 1)
    let window = makeWindow(
      totalCount: 1,
      windowStart: 0,
      windowEnd: 1,
      hasOlder: false,
      hasNewer: false
    )
    let navigation = makeNavigation(timeline: timeline, window: window)

    let text = SessionTimelineCountSummary.statusText(
      navigation: navigation,
      filterSummary: .empty,
      filterMatchCount: nil
    )

    #expect(text == "1 event")
  }

  @Test("Partial latest window renders Showing 1-N of total")
  func partialLatestWindowRendersShowingPrefix() {
    let timeline = makeTimeline(count: 64)
    let window = makeWindow(
      totalCount: 200,
      windowStart: 0,
      windowEnd: 64,
      hasOlder: true,
      hasNewer: false
    )
    let navigation = makeNavigation(timeline: timeline, window: window)

    let text = SessionTimelineCountSummary.statusText(
      navigation: navigation,
      filterSummary: .empty,
      filterMatchCount: nil
    )

    #expect(text == "Showing 1-64 of 200")
  }

  @Test("Middle window renders Showing start-end of total")
  func middleWindowRendersShowingRange() {
    let timeline = makeTimeline(count: 50)
    let window = makeWindow(
      totalCount: 200,
      windowStart: 120,
      windowEnd: 170,
      hasOlder: true,
      hasNewer: true
    )
    let navigation = makeNavigation(timeline: timeline, window: window)

    let text = SessionTimelineCountSummary.statusText(
      navigation: navigation,
      filterSummary: .empty,
      filterMatchCount: nil
    )

    #expect(text == "Showing 121-170 of 200")
  }

  private func makeNavigation(
    timeline: [TimelineEntry],
    window: TimelineWindowResponse?
  ) -> SessionTimelineWindowNavigation {
    SessionTimelineWindowNavigation(
      timeline: timeline,
      timelineWindow: window,
      isLoading: false
    )
  }

  private func makeTimeline(count: Int) -> [TimelineEntry] {
    (0..<count).map { index in
      TimelineEntry(
        entryId: "count-summary-entry-\(index)",
        recordedAt: String(format: "2026-04-14T03:%02d:00Z", 59 - (index % 60)),
        kind: "task_checkpoint",
        sessionId: "session-count-summary",
        agentId: "agent-1",
        taskId: nil,
        summary: "Count summary entry \(index)",
        payload: .object([:])
      )
    }
  }

  private func makeWindow(
    totalCount: Int,
    windowStart: Int,
    windowEnd: Int,
    hasOlder: Bool,
    hasNewer: Bool
  ) -> TimelineWindowResponse {
    TimelineWindowResponse(
      revision: 1,
      totalCount: totalCount,
      windowStart: windowStart,
      windowEnd: windowEnd,
      hasOlder: hasOlder,
      hasNewer: hasNewer,
      oldestCursor: nil,
      newestCursor: nil,
      entries: nil,
      unchanged: false
    )
  }
}
