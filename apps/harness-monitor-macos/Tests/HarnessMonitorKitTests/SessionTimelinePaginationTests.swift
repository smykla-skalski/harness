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
        == TimelineWindowRequest(scope: .summary, limit: 6, before: oldestCursor)
    )
    #expect(navigation.request(for: .latest) == .latest(limit: 6))
    #expect(
      navigation.request(for: .newer)
        == TimelineWindowRequest(scope: .summary, limit: 6, after: newestCursor)
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
    #expect(navigation.request(for: .latest) == .latest(limit: 6))
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
}
