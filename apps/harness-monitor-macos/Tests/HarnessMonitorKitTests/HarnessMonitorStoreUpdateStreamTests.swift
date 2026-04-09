import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store update streams")
struct HarnessMonitorStoreUpdateStreamTests {
  @Test("Global session update refreshes a non-selected summary without a full refetch")
  func globalSessionUpdateRefreshesNonSelectedSummaryWithoutRefetch() async {
    let client = RecordingHarnessClient()
    let primary = makeSession(
      .init(
        sessionId: "sess-primary",
        context: "Primary cockpit",
        status: .active,
        leaderId: "leader-primary",
        observeId: "observe-primary",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let secondary = makeSession(
      .init(
        sessionId: "sess-secondary",
        context: "Secondary lane",
        status: .active,
        leaderId: "leader-secondary",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 0
      ))
    let updatedSecondary = SessionSummary(
      projectId: secondary.projectId,
      projectName: secondary.projectName,
      projectDir: secondary.projectDir,
      contextRoot: secondary.contextRoot,
      sessionId: secondary.sessionId,
      title: secondary.title,
      context: "Secondary lane updated",
      status: .ended,
      createdAt: secondary.createdAt,
      updatedAt: "2026-03-31T12:01:00Z",
      lastActivityAt: "2026-03-31T12:01:00Z",
      leaderId: secondary.leaderId,
      observeId: secondary.observeId,
      pendingLeaderTransfer: secondary.pendingLeaderTransfer,
      metrics: secondary.metrics
    )

    client.configureSessions(
      summaries: [primary, secondary],
      detailsByID: [
        primary.sessionId: makeSessionDetail(
          summary: primary,
          workerID: "worker-primary",
          workerName: "Worker Primary"
        ),
        secondary.sessionId: makeSessionDetail(
          summary: secondary,
          workerID: "worker-secondary",
          workerName: "Worker Secondary"
        ),
      ]
    )
    client.configureGlobalStream(events: [
      .sessionUpdated(
        recordedAt: "2026-03-31T12:01:00Z",
        sessionId: secondary.sessionId,
        detail: makeSessionDetail(
          summary: updatedSecondary,
          workerID: "worker-secondary",
          workerName: "Worker Secondary"
        ),
        timeline: PreviewFixtures.timeline
      )
    ])

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )

    await store.bootstrap()
    await store.selectSession(primary.sessionId)
    let baselineHealthCalls = client.readCallCount(.health)
    try? await Task.sleep(for: .milliseconds(60))

    let updated = store.sessions.first { $0.sessionId == secondary.sessionId }
    #expect(updated?.context == "Secondary lane updated")
    #expect(updated?.status == .ended)
    #expect(store.selectedSession?.session.sessionId == primary.sessionId)
    #expect(client.readCallCount(.health) == baselineHealthCalls)
    #expect(client.readCallCount(.projects) == 1)
    #expect(client.readCallCount(.sessions) == 1)
    #expect(client.readCallCount(.sessionDetail(primary.sessionId)) == 1)

    store.stopAllStreams()
  }

  @Test("Global session snapshot reloads stale selected detail")
  func globalSessionSnapshotReloadsStaleSelectedDetail() async {
    let client = RecordingHarnessClient()
    let summary = makeSession(
      .init(
        sessionId: "sess-selected",
        context: "Selected cockpit",
        status: .active,
        leaderId: "leader-selected",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let updatedSummary = makeUpdatedSession(
      summary,
      context: "Selected cockpit updated by external worker",
      updatedAt: "2026-03-31T12:02:00Z",
      agentCount: 2
    )
    let initialDetail = makeSessionDetail(
      summary: summary,
      workerID: "worker-before",
      workerName: "Worker Before"
    )
    let updatedDetail = makeSessionDetail(
      summary: updatedSummary,
      workerID: "worker-after",
      workerName: "Worker After"
    )
    let refreshedTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-after",
      summary: "External worker joined"
    )

    client.configureSessions(
      summaries: [summary],
      detailsByID: [summary.sessionId: initialDetail],
      timelinesBySessionID: [summary.sessionId: PreviewFixtures.timeline]
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )

    await store.bootstrap()
    await store.selectSession(summary.sessionId)
    #expect(
      store.selectedSession?.agents.contains(where: { $0.agentId == "worker-before" }) == true
    )

    let baselineDetailCalls = client.readCallCount(.sessionDetail(summary.sessionId))
    client.configureSessions(
      summaries: [updatedSummary],
      detailsByID: [summary.sessionId: updatedDetail],
      timelinesBySessionID: [summary.sessionId: refreshedTimeline]
    )

    store.applyGlobalPushEvent(
      .sessionsUpdated(
        recordedAt: "2026-03-31T12:02:00Z",
        projects: [makeProject(totalSessionCount: 1, activeSessionCount: 1)],
        sessions: [updatedSummary]
      )
    )

    try? await Task.sleep(for: .milliseconds(80))

    #expect(store.selectedSession?.session.context == updatedSummary.context)
    #expect(
      store.selectedSession?.agents.contains(where: { $0.agentId == "worker-after" }) == true
    )
    #expect(store.timeline == refreshedTimeline)
    #expect(
      client.readCallCount(.sessionDetail(summary.sessionId)) == baselineDetailCalls + 1
    )

    store.stopAllStreams()
  }

  @Test("Selected session update without timeline refetches timeline separately")
  func selectedSessionUpdateWithoutTimelineRefetchesTimelineSeparately() async {
    let client = RecordingHarnessClient()
    let summary = makeSession(
      .init(
        sessionId: "sess-selected",
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
    let refreshedTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-selected",
      summary: "Refetched timeline"
    )

    client.configureSessions(
      summaries: [summary],
      detailsByID: [summary.sessionId: initialDetail],
      timelinesBySessionID: [summary.sessionId: initialTimeline]
    )
    client.configureSessionStream(
      events: [
        .sessionUpdated(
          recordedAt: "2026-03-31T12:03:00Z",
          sessionId: summary.sessionId,
          detail: updatedDetail
        )
      ],
      for: summary.sessionId
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )

    await store.bootstrap()
    await store.selectSession(summary.sessionId)
    let baselineTimelineCalls = client.readCallCount(.timeline(summary.sessionId))

    client.configureSessions(
      summaries: [updatedSummary],
      detailsByID: [summary.sessionId: updatedDetail],
      timelinesBySessionID: [summary.sessionId: refreshedTimeline]
    )

    try? await Task.sleep(for: .milliseconds(1_050))

    #expect(store.selectedSession?.session.context == "Selected cockpit updated")
    #expect(store.timeline == refreshedTimeline)
    #expect(client.readCallCount(.timeline(summary.sessionId)) == baselineTimelineCalls + 1)

    store.stopAllStreams()
  }

  @Test("Selected session update with deferred extensions preserves visible signals")
  func selectedSessionUpdateWithDeferredExtensionsPreservesVisibleSignals() async {
    let client = RecordingHarnessClient()
    let updatedSummary = SessionSummary(
      projectId: PreviewFixtures.summary.projectId,
      projectName: PreviewFixtures.summary.projectName,
      projectDir: PreviewFixtures.summary.projectDir,
      contextRoot: PreviewFixtures.summary.contextRoot,
      checkoutId: PreviewFixtures.summary.checkoutId,
      checkoutRoot: PreviewFixtures.summary.checkoutRoot,
      isWorktree: PreviewFixtures.summary.isWorktree,
      worktreeName: PreviewFixtures.summary.worktreeName,
      sessionId: PreviewFixtures.summary.sessionId,
      title: PreviewFixtures.summary.title,
      context: "Cockpit context updated",
      status: PreviewFixtures.summary.status,
      createdAt: PreviewFixtures.summary.createdAt,
      updatedAt: "2026-03-31T12:04:00Z",
      lastActivityAt: "2026-03-31T12:04:00Z",
      leaderId: PreviewFixtures.summary.leaderId,
      observeId: PreviewFixtures.summary.observeId,
      pendingLeaderTransfer: PreviewFixtures.summary.pendingLeaderTransfer,
      metrics: PreviewFixtures.summary.metrics
    )
    let coreOnlyDetail = SessionDetail(
      session: updatedSummary,
      agents: PreviewFixtures.detail.agents,
      tasks: PreviewFixtures.detail.tasks,
      signals: [],
      observer: nil,
      agentActivity: []
    )

    client.configureSessions(
      summaries: [PreviewFixtures.summary],
      detailsByID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )
    client.configureSessionStream(
      events: [
        .sessionUpdated(
          recordedAt: "2026-03-31T12:04:00Z",
          sessionId: PreviewFixtures.summary.sessionId,
          detail: coreOnlyDetail,
          extensionsPending: true
        )
      ],
      for: PreviewFixtures.summary.sessionId
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )

    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    try? await Task.sleep(for: .milliseconds(60))

    #expect(store.selectedSession?.session.context == "Cockpit context updated")
    #expect(store.selectedSession?.signals == PreviewFixtures.signals)
    #expect(store.timeline == PreviewFixtures.timeline)

    store.stopAllStreams()
  }
}
