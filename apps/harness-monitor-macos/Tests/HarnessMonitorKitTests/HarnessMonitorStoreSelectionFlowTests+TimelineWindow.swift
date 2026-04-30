import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreSelectionFlowTests {
  @Test("Loading a selected timeline window replaces the visible cursor window")
  func loadingSelectedTimelineWindowReplacesVisibleCursorWindow() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-cursor",
        context: "Cursor window lane",
        status: .active,
        leaderId: "leader-window-cursor",
        observeId: "observe-window-cursor",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-cursor",
      workerName: "Window Cursor Worker"
    )
    let fullTimeline = (0..<24).map { index in
      TimelineEntry(
        entryId: "timeline-window-cursor-\(index)",
        recordedAt: String(format: "2026-04-30T10:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Window cursor \(index)",
        payload: .object([:])
      )
    }
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: fullTimeline],
      detail: detail
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(summary.sessionId)
    let olderRequest = TimelineWindowRequest(
      scope: .summary,
      limit: 6,
      before: TimelineCursor(
        recordedAt: fullTimeline[9].recordedAt,
        entryId: fullTimeline[9].entryId
      )
    )

    await store.loadSelectedTimelineWindow(request: olderRequest)

    #expect(
      client.recordedTimelineWindowRequests(for: summary.sessionId) == [
        .latest(limit: 10),
        olderRequest,
      ]
    )
    #expect(store.timeline == Array(fullTimeline[10..<16]))
    #expect(store.timelineWindow?.windowStart == 10)
    #expect(store.timelineWindow?.windowEnd == 16)
    #expect(store.timelineWindow?.hasOlder == true)
    #expect(store.timelineWindow?.hasNewer == true)
  }
}
