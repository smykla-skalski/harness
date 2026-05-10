import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreSelectionFlowTests {
  @Test("Rolling older timeline chunks evict newer rows atomically")
  func rollingOlderTimelineChunksEvictNewerRowsAtomically() async throws {
    let fixture = makeRollingWindowFixture(
      sessionID: "sess-window-rolling-older",
      entryPrefix: "timeline-rolling-older",
      count: 36
    )
    let store = await makeBootstrappedStore(client: fixture.client)

    await store.selectSession(fixture.summary.sessionId)
    await store.appendSelectedTimelineOlderChunk(limit: 4, retainedLimit: 12)
    #expect(store.timeline == Array(fixture.timeline[2..<14]))
    #expect(store.timelineWindow?.windowStart == 2)
    #expect(store.timelineWindow?.windowEnd == 14)
    #expect(store.timelineWindow?.hasNewer == true)
    #expect(store.timelineWindow?.hasOlder == true)

    await store.appendSelectedTimelineOlderChunk(limit: 3, retainedLimit: 12)

    #expect(store.timeline == Array(fixture.timeline[5..<17]))
    #expect(store.timeline.count == 12)
    #expect(store.timelineWindow?.windowStart == 5)
    #expect(store.timelineWindow?.windowEnd == 17)
  }

  @Test("Rolling newer timeline window evicts older rows atomically")
  func rollingNewerTimelineWindowEvictsOlderRowsAtomically() async throws {
    let fixture = makeRollingWindowFixture(
      sessionID: "sess-window-rolling-newer",
      entryPrefix: "timeline-rolling-newer",
      count: 40
    )
    let store = await makeBootstrappedStore(client: fixture.client)
    let middleRequest = TimelineWindowRequest(
      scope: .summary,
      limit: 12,
      before: fixture.timeline[11].timelineCursor
    )

    await store.selectSession(fixture.summary.sessionId)
    await store.loadSelectedTimelineWindow(request: middleRequest)
    let currentWindow = try #require(store.timelineWindow)
    let newerRequest = try #require(currentWindow.requestNewer(limit: 5))
    await store.loadSelectedTimelineWindow(request: newerRequest, retainedLimit: 12)

    #expect(store.timeline == Array(fixture.timeline[7..<19]))
    #expect(store.timeline.count == 12)
    #expect(store.timelineWindow?.windowStart == 7)
    #expect(store.timelineWindow?.windowEnd == 19)
    #expect(store.timelineWindow?.hasNewer == true)
    #expect(store.timelineWindow?.hasOlder == true)
  }

  private func makeRollingWindowFixture(
    sessionID: String,
    entryPrefix: String,
    count: Int
  ) -> RollingWindowFixture {
    let summary = makeSession(
      .init(
        sessionId: sessionID,
        context: "Window rolling lane",
        status: .active,
        leaderId: "leader-\(sessionID)",
        observeId: "observe-\(sessionID)",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-\(sessionID)",
      workerName: "Window Rolling Worker"
    )
    let timeline = (0..<count).map { index in
      TimelineEntry(
        entryId: "\(entryPrefix)-\(index)",
        recordedAt: String(format: "2026-04-14T03:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Window rolling \(index)",
        payload: .object([:])
      )
    }
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: timeline],
      detail: detail
    )
    return RollingWindowFixture(summary: summary, timeline: timeline, client: client)
  }
}

private struct RollingWindowFixture {
  let summary: SessionSummary
  let timeline: [TimelineEntry]
  let client: RecordingHarnessClient
}

private extension TimelineEntry {
  var timelineCursor: TimelineCursor {
    TimelineCursor(recordedAt: recordedAt, entryId: entryId)
  }
}

private extension TimelineWindowResponse {
  func requestNewer(limit: Int) -> TimelineWindowRequest? {
    guard let newestCursor else { return nil }
    return TimelineWindowRequest(scope: .summary, limit: limit, after: newestCursor)
  }
}
