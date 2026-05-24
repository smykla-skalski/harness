import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("Streaming push with timeline preserves hasOlder + totalCount")
  func streamingPushPreservesPagedWindowMetadata() async throws {
    let client = RecordingHarnessClient()
    let summary = makeSession(
      .init(
        sessionId: "sess-window-preserve",
        context: "Window preservation",
        status: .active,
        leaderId: "leader-window-preserve",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-preserve",
      workerName: "Worker Window Preserve"
    )
    let fullTimeline = (0..<60).map { index in
      TimelineEntry(
        entryId: "preserve-\(index)",
        recordedAt: String(format: "2026-04-15T08:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Preserve entry \(index)",
        payload: .object([:])
      )
    }

    client.configureSessions(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: fullTimeline]
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    await store.bootstrap()
    await store.selectSession(summary.sessionId)

    let initialWindow = try #require(store.timelineWindow)
    #expect(initialWindow.hasOlder == true)
    #expect(initialWindow.totalCount == fullTimeline.count)

    let pushedTimeline = Array(fullTimeline.prefix(initialWindow.windowEnd))
    store.applySessionPushEvent(
      .sessionUpdated(
        recordedAt: "2026-04-15T08:30:00Z",
        sessionId: summary.sessionId,
        detail: detail,
        timeline: pushedTimeline
      )
    )

    let postPushWindow = try #require(store.timelineWindow)
    #expect(postPushWindow.hasOlder == true)
    #expect(postPushWindow.totalCount == fullTimeline.count)

    store.stopAllStreams()
  }
}
