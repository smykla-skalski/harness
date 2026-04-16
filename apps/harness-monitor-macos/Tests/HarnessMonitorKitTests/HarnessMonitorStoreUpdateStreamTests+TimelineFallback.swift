import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  private struct SelectedSessionUpdateFixture {
    let summary: SessionSummary
    let updatedSummary: SessionSummary
    let initialDetail: SessionDetail
    let updatedDetail: SessionDetail
    let initialTimeline: [TimelineEntry]
  }

  @Test("Selected session update waits before timeline fallback refetch")
  func selectedSessionUpdateWaitsBeforeTimelineFallbackRefetch() async {
    let client = RecordingHarnessClient()
    let summary = makeSession(
      .init(
        sessionId: "sess-selected-timeline-delay",
        context: "Selected cockpit",
        status: .active,
        leaderId: "leader-selected",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let updatedSummary = SessionSummary(
      projectId: summary.projectId,
      projectName: summary.projectName,
      projectDir: summary.projectDir,
      contextRoot: summary.contextRoot,
      sessionId: summary.sessionId,
      title: summary.title,
      context: "Selected cockpit updated",
      status: .active,
      createdAt: summary.createdAt,
      updatedAt: "2026-03-31T12:03:00Z",
      lastActivityAt: "2026-03-31T12:03:00Z",
      leaderId: summary.leaderId,
      observeId: summary.observeId,
      pendingLeaderTransfer: summary.pendingLeaderTransfer,
      metrics: summary.metrics
    )
    let initialDetail = makeSessionDetail(
      summary: summary,
      workerID: "worker-selected",
      workerName: "Worker Selected"
    )
    let updatedDetail = makeSessionDetail(
      summary: updatedSummary,
      workerID: "worker-selected",
      workerName: "Worker Selected"
    )
    let initialTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-selected",
      summary: "Initial timeline"
    )

    client.configureSessions(
      summaries: [summary],
      detailsByID: [summary.sessionId: initialDetail],
      timelinesBySessionID: [summary.sessionId: initialTimeline]
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )

    await store.bootstrap()
    await store.selectSession(summary.sessionId)
    let baselineTimelineCalls = client.readCallCount(.timeline(summary.sessionId))

    store.applySessionPushEvent(
      .sessionUpdated(
        recordedAt: "2026-03-31T12:03:00Z",
        sessionId: summary.sessionId,
        detail: updatedDetail
      )
    )

    try? await Task.sleep(for: .milliseconds(1_200))

    #expect(store.selectedSession?.session.context == updatedSummary.context)
    #expect(store.timeline == initialTimeline)
    #expect(client.readCallCount(.timeline(summary.sessionId)) == baselineTimelineCalls)

    store.stopAllStreams()
  }

  @Test("Selected session update without timeline refetches timeline separately")
  func selectedSessionUpdateWithoutTimelineRefetchesTimelineSeparately() async throws {
    let client = RecordingHarnessClient()
    let fixture = makeSelectedSessionUpdateFixture(sessionID: "sess-selected")
    // Two entries so revision (Int64(count)=2) differs from initialTimeline's revision (1),
    // preventing the recording client from returning unchanged=true on the fallback fetch.
    let refreshedTimeline = makeRefreshedTimeline(sessionID: fixture.summary.sessionId)

    client.configureSessions(
      summaries: [fixture.summary],
      detailsByID: [fixture.summary.sessionId: fixture.initialDetail],
      timelinesBySessionID: [fixture.summary.sessionId: fixture.initialTimeline]
    )
    client.configureSessionStream(
      events: [
        .sessionUpdated(
          recordedAt: "2026-03-31T12:03:00Z",
          sessionId: fixture.summary.sessionId,
          detail: fixture.updatedDetail
        )
      ],
      for: fixture.summary.sessionId
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.sessionPushFallbackDelay = .milliseconds(20)

    await store.bootstrap()
    await store.selectSession(fixture.summary.sessionId)
    let selectedWindow = try #require(store.timelineWindow)
    let baselineTimelineCalls = client.readCallCount(.timelineWindow(fixture.summary.sessionId))

    client.configureSessions(
      summaries: [fixture.updatedSummary],
      detailsByID: [fixture.summary.sessionId: fixture.updatedDetail],
      timelinesBySessionID: [fixture.summary.sessionId: refreshedTimeline]
    )
    try? await Task.sleep(for: .milliseconds(80))

    #expect(store.selectedSession?.session.context == fixture.updatedSummary.context)
    #expect(store.timeline == refreshedTimeline)
    #expect(
      client.readCallCount(.timelineWindow(fixture.summary.sessionId)) == baselineTimelineCalls + 1
    )
    #expect(
      client.recordedTimelineWindowRequests(for: fixture.summary.sessionId).last
        == .latest(
          limit: max(
            HarnessMonitorStore.initialSelectedTimelineWindowLimit, selectedWindow.pageSize
          ),
          knownRevision: selectedWindow.revision
        )
    )

    store.stopAllStreams()
  }

  private func makeSelectedSessionUpdateFixture(sessionID: String) -> SelectedSessionUpdateFixture {
    let summary = makeSession(
      .init(
        sessionId: sessionID,
        context: "Selected cockpit",
        status: .active,
        leaderId: "leader-selected",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let updatedSummary = SessionSummary(
      projectId: summary.projectId,
      projectName: summary.projectName,
      projectDir: summary.projectDir,
      contextRoot: summary.contextRoot,
      sessionId: summary.sessionId,
      title: summary.title,
      context: "Selected cockpit updated",
      status: .active,
      createdAt: summary.createdAt,
      updatedAt: "2026-03-31T12:03:00Z",
      lastActivityAt: "2026-03-31T12:03:00Z",
      leaderId: summary.leaderId,
      observeId: summary.observeId,
      pendingLeaderTransfer: summary.pendingLeaderTransfer,
      metrics: summary.metrics
    )
    let initialDetail = makeSessionDetail(
      summary: summary,
      workerID: "worker-selected",
      workerName: "Worker Selected"
    )
    let updatedDetail = makeSessionDetail(
      summary: updatedSummary,
      workerID: "worker-selected",
      workerName: "Worker Selected"
    )
    let initialTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-selected",
      summary: "Initial timeline"
    )
    return SelectedSessionUpdateFixture(
      summary: summary,
      updatedSummary: updatedSummary,
      initialDetail: initialDetail,
      updatedDetail: updatedDetail,
      initialTimeline: initialTimeline
    )
  }

  private func makeRefreshedTimeline(sessionID: String) -> [TimelineEntry] {
    [
      TimelineEntry(
        entryId: "refreshed-a-\(sessionID)",
        recordedAt: "2026-03-29T10:00:00Z",
        kind: "task_checkpoint",
        sessionId: sessionID,
        agentId: "worker-selected",
        taskId: nil,
        summary: "Refetched timeline",
        payload: .object([:])
      ),
      TimelineEntry(
        entryId: "refreshed-b-\(sessionID)",
        recordedAt: "2026-03-29T10:01:00Z",
        kind: "task_checkpoint",
        sessionId: sessionID,
        agentId: "worker-selected",
        taskId: nil,
        summary: "Refetched timeline entry 2",
        payload: .object([:])
      ),
    ]
  }
}
