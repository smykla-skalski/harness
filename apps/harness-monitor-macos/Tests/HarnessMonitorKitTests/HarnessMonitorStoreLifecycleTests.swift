import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store lifecycle")
struct HarnessMonitorStoreLifecycleTests {
  @Test("bootstrapIfNeeded only bootstraps once")
  func bootstrapIfNeededOnlyBootstrapsOnce() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    await store.bootstrapIfNeeded()
    #expect(store.connectionState == .online)

    store.connectionState = .idle

    await store.bootstrapIfNeeded()
    #expect(store.connectionState == .idle)
  }

  @Test("Start daemon failure sets offline state and error")
  func startDaemonFailureSetsOfflineStateAndError() async {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    #expect(
      store.connectionState
        == .offline(DaemonControlError.daemonDidNotStart.localizedDescription)
    )
    #expect(store.lastError != nil)
    #expect(store.isDaemonActionInFlight == false)
  }

  @Test("Prime session selection clears detail and timeline")
  func primeSessionSelectionClearsDetailAndTimeline() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession != nil)
    #expect(store.timeline.isEmpty == false)

    store.primeSessionSelection("different-session")

    #expect(store.selectedSessionID == "different-session")
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.isSelectionLoading)
    #expect(store.inspectorSelection == .none)
  }

  @Test("Prime session selection with nil clears everything")
  func primeSessionSelectionWithNilClearsEverything() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.primeSessionSelection(nil)

    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.isSelectionLoading == false)
  }

  @Test("Prime session selection with same session is a no-op")
  func primeSessionSelectionWithSameSessionIsNoOp() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    let originalDetail = store.selectedSession

    store.primeSessionSelection(PreviewFixtures.summary.sessionId)

    #expect(store.selectedSession == originalDetail)
    #expect(store.isSelectionLoading == false)
  }

  @Test("Refresh diagnostics without client falls back to daemon status")
  func refreshDiagnosticsWithoutClientFallsBackToDaemonStatus() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.diagnostics = nil

    await store.refreshDiagnostics()

    #expect(store.diagnostics == nil)
    #expect(store.isDiagnosticsRefreshInFlight == false)
  }

  @Test("Selecting nil session stops session stream subscription")
  func selectingNilSessionStopsSubscription() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    #expect(store.subscribedSessionIDs.isEmpty == false)

    await store.selectSession(nil)

    #expect(store.subscribedSessionIDs.isEmpty)
    #expect(store.selectedSessionID == nil)
  }

  @Test("Prepare for termination cancels background work and shuts down the client")
  func prepareForTerminationCancelsBackgroundWorkAndShutsDownClient() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.showLastAction("Refresh")

    #expect(store.globalStreamTask != nil)
    #expect(store.sessionStreamTask != nil)
    #expect(store.connectionProbeTask != nil)
    #expect(store.lastAction == "Refresh")

    await store.prepareForTermination()

    #expect(store.client == nil)
    #expect(store.globalStreamTask == nil)
    #expect(store.sessionStreamTask == nil)
    #expect(store.connectionProbeTask == nil)
    #expect(store.lastAction.isEmpty)
    #expect(client.shutdownCallCount() == 1)
  }

  @Test("Global session update refreshes a non-selected summary without a full refetch")
  func globalSessionUpdateRefreshesNonSelectedSummaryWithoutRefetch() async {
    let client = RecordingHarnessClient()
    let primary = makeSession(.init(
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
    let secondary = makeSession(.init(
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

  @Test("Selected session update without timeline refetches timeline separately")
  func selectedSessionUpdateWithoutTimelineRefetchesTimelineSeparately() async {
    let client = RecordingHarnessClient()
    let summary = makeSession(.init(
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

  @Test("Preview store factory preloads cockpit state without bootstrap")
  func previewStoreFactoryPreloadsCockpitState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)

    #expect(store.connectionState == .online)
    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession == PreviewFixtures.detail)
    #expect(store.timeline == PreviewFixtures.timeline)
    #expect(store.sessions == [PreviewFixtures.summary])
    #expect(store.groupedSessions.count == 1)
    #expect(store.isBookmarked(sessionId: PreviewFixtures.summary.sessionId))
  }

  @Test("Preview store factory seeds offline cached state")
  func previewStoreFactorySeedsOfflineCachedState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .offlineCached)

    #expect(
      store.connectionState == .offline(DaemonControlError.daemonOffline.localizedDescription)
    )
    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession == PreviewFixtures.detail)
    #expect(store.timeline == PreviewFixtures.timeline)
    #expect(store.sessions == [PreviewFixtures.summary])
    #expect(store.isShowingCachedData)
    #expect(store.persistedSessionCount == 1)

    switch store.sessionDataAvailability {
    case .persisted(let reason, let sessionCount, let lastSnapshotAt):
      #expect(sessionCount == 1)
      #expect(lastSnapshotAt != nil)
      switch reason {
      case .daemonOffline(let message):
        #expect(message == DaemonControlError.daemonOffline.localizedDescription)
      case .liveDataUnavailable:
        Issue.record("Expected offline cached preview to report daemonOffline reason")
      }
    case .live, .unavailable:
      Issue.record("Expected offline cached preview to expose persisted availability")
    }
  }

  @Test("Preview store factory exposes overflow sidebar data immediately")
  func previewStoreFactorySeedsOverflowSidebarState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .sidebarOverflow)

    #expect(store.sessionFilter == .all)
    #expect(store.sessions.count == PreviewFixtures.overflowSessions.count)
    #expect(store.filteredSessionCount == PreviewFixtures.overflowSessions.count)
    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession == PreviewFixtures.detail)
    #expect(store.groupedSessions.isEmpty == false)
  }

  @Test("Preview store factory seeds dashboard state without a selected session")
  func previewStoreFactorySeedsDashboardState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

    #expect(store.connectionState == .online)
    #expect(store.sessionFilter == .active)
    #expect(store.sessions == [PreviewFixtures.summary])
    #expect(store.filteredSessionCount == 1)
    #expect(store.groupedSessions.count == 1)
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.isBookmarked(sessionId: PreviewFixtures.summary.sessionId))
  }

  @Test("Preview store factory seeds empty state without stale selection")
  func previewStoreFactorySeedsEmptyState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)

    #expect(
      store.connectionState == .offline(DaemonControlError.daemonOffline.localizedDescription)
    )
    #expect(store.sessionFilter == .active)
    #expect(store.sessions.isEmpty)
    #expect(store.filteredSessionCount == 0)
    #expect(store.groupedSessions.isEmpty)
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.isShowingCachedData == false)
  }

  @Test("Empty preview daemon starts offline and start daemon connects")
  func emptyPreviewDaemonTransitionsOnlineAfterStart() async {
    let store = HarnessMonitorStore(daemonController: PreviewDaemonController(mode: .empty))

    await store.bootstrap()

    #expect(
      store.connectionState == .offline(DaemonControlError.daemonOffline.localizedDescription)
    )
    #expect(store.daemonStatus?.launchAgent.installed == false)
    #expect(store.sessions.isEmpty)

    await store.startDaemon()

    #expect(store.connectionState == .online)
    #expect(store.daemonStatus?.launchAgent.installed == false)
    #expect(store.sessions.isEmpty)
    #expect(store.health?.status == "ok")
  }
}
