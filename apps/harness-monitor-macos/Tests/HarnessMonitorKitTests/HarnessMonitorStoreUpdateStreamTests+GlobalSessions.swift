import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
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
    store.selectedSessionRefreshFallbackDelay = .milliseconds(20)

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

  @Test(
    "Global session snapshot keeps the visible cockpit stable while selected-session fallback refetch is pending"
  )
  func globalSessionSnapshotKeepsVisibleCockpitStableWhileFallbackRefetchIsPending() async {
    let client = RecordingHarnessClient()
    let summary = PreviewFixtures.summary
    let updatedSummary = makeUpdatedSession(
      summary,
      context: "Selected cockpit updated by summary push",
      updatedAt: "2026-03-31T12:02:00Z",
      agentCount: 2
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
      summaries: [summary],
      detailsByID: [summary.sessionId: PreviewFixtures.detail],
      timelinesBySessionID: [summary.sessionId: PreviewFixtures.timeline]
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.selectedSessionRefreshFallbackDelay = .milliseconds(20)

    await store.bootstrap()
    store.activeTransport = .webSocket
    await store.selectSession(summary.sessionId)
    #expect(store.selectedSession?.session.context == summary.context)
    #expect(store.selectedSession?.signals == PreviewFixtures.signals)
    #expect(store.selectedSession?.agentActivity == PreviewFixtures.agentActivity)
    #expect(store.timeline == PreviewFixtures.timeline)

    let baselineDetailCalls = client.readCallCount(.sessionDetail(summary.sessionId))
    let baselineTimelineWindowCalls = client.readCallCount(.timelineWindow(summary.sessionId))
    client.configureSessions(
      summaries: [updatedSummary],
      detailsByID: [summary.sessionId: coreOnlyDetail],
      timelinesBySessionID: [summary.sessionId: PreviewFixtures.timeline]
    )
    client.configureTimelineWindowDelay(.milliseconds(250), for: summary.sessionId)

    store.applyGlobalPushEvent(
      .sessionsUpdated(
        recordedAt: "2026-03-31T12:02:00Z",
        projects: [makeProject(totalSessionCount: 1, activeSessionCount: 1)],
        sessions: [updatedSummary]
      )
    )

    try? await Task.sleep(for: .milliseconds(80))

    #expect(store.contentUI.session.selectedSessionSummary?.context == updatedSummary.context)
    #expect(store.selectedSession?.session.context == updatedSummary.context)
    #expect(store.selectedSession?.signals == PreviewFixtures.signals)
    #expect(store.selectedSession?.agentActivity == PreviewFixtures.agentActivity)
    #expect(store.timeline == PreviewFixtures.timeline)
    #expect(store.contentUI.sessionDetail.presentedSessionDetail?.signals == PreviewFixtures.signals)
    #expect(
      store.contentUI.sessionDetail.presentedSessionDetail?.agentActivity
        == PreviewFixtures.agentActivity
    )
    #expect(store.contentUI.sessionDetail.presentedTimeline == PreviewFixtures.timeline)
    #expect(store.contentUI.session.isSelectionLoading)
    #expect(client.readCallCount(.sessionDetail(summary.sessionId)) == baselineDetailCalls + 1)
    #expect(
      client.readCallCount(.timelineWindow(summary.sessionId))
        == baselineTimelineWindowCalls + 1
    )

    store.stopAllStreams()
  }

  @Test("Global session snapshot prefers selected-session pushes over full refetch")
  func globalSessionSnapshotPrefersSelectedSessionPushesOverFullRefetch() async {
    let client = RecordingHarnessClient()
    let summary = makeSession(
      .init(
        sessionId: "sess-selected-push-preferred",
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
      context: "Selected cockpit updated by push",
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

    client.configureSessions(
      summaries: [summary],
      detailsByID: [summary.sessionId: initialDetail],
      timelinesBySessionID: [summary.sessionId: PreviewFixtures.timeline]
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.selectedSessionRefreshFallbackDelay = .milliseconds(20)

    await store.bootstrap()
    await store.selectSession(summary.sessionId)
    #expect(
      store.selectedSession?.agents.contains(where: { $0.agentId == "worker-before" }) == true
    )

    let baselineDetailCalls = client.readCallCount(.sessionDetail(summary.sessionId))
    store.applyGlobalPushEvent(
      .sessionsUpdated(
        recordedAt: "2026-03-31T12:02:00Z",
        projects: [makeProject(totalSessionCount: 1, activeSessionCount: 1)],
        sessions: [updatedSummary]
      )
    )
    store.applySessionPushEvent(
      .sessionUpdated(
        recordedAt: "2026-03-31T12:02:01Z",
        sessionId: summary.sessionId,
        detail: updatedDetail,
        extensionsPending: true
      )
    )
    store.applySessionPushEvent(
      DaemonPushEvent(
        recordedAt: "2026-03-31T12:02:02Z",
        sessionId: summary.sessionId,
        kind: .sessionExtensions(
          SessionExtensionsPayload(
            sessionId: summary.sessionId,
            signals: updatedDetail.signals,
            observer: updatedDetail.observer,
            agentActivity: updatedDetail.agentActivity
          )
        )
      )
    )

    try? await Task.sleep(for: .milliseconds(80))

    #expect(store.selectedSession?.session.context == updatedSummary.context)
    #expect(
      store.selectedSession?.agents.contains(where: { $0.agentId == "worker-after" }) == true
    )
    #expect(client.readCallCount(.sessionDetail(summary.sessionId)) == baselineDetailCalls)

    store.stopAllStreams()
  }
}
