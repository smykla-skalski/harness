import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor preview store lifecycle")
struct HarnessMonitorPreviewStoreLifecycleTests {
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

  @Test("Preview store factory preloads the empty cockpit state without bootstrap")
  func previewStoreFactoryPreloadsEmptyCockpitState() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .emptyCockpit)

    #expect(store.connectionState == .online)
    #expect(store.selectedSessionID == PreviewFixtures.emptyCockpitSummary.sessionId)
    #expect(store.selectedSession == PreviewFixtures.emptyCockpitDetail)
    #expect(store.timeline.isEmpty)
    #expect(store.sessions == [PreviewFixtures.emptyCockpitSummary])
    #expect(store.groupedSessions.count == 1)
    #expect(store.selectedSession?.agents.isEmpty == true)
    #expect(store.selectedSession?.tasks.isEmpty == true)
    #expect(store.selectedSession?.signals.isEmpty == true)
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

  @Test("Preview store factory seeds and refreshes agent TUI overflow sessions")
  func previewStoreFactorySeedsAgentTuiOverflowState() async {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .agentTuiOverflow)
    let expectedTuiIDs = AgentTuiListResponse(tuis: AgentTuiPreviewSupport.overflowMixed)
      .canonicallySorted(roleByAgent: [:])
      .tuis
      .map(\.tuiId)

    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedAgentTuis.map(\.tuiId) == expectedTuiIDs)
    #expect(store.selectedAgentTui?.tuiId == expectedTuiIDs.first)

    await store.bootstrap()
    let didRefresh = await store.refreshSelectedAgentTuis()

    #expect(didRefresh)
    #expect(store.selectedAgentTuis.map(\.tuiId) == expectedTuiIDs)
    #expect(store.selectedAgentTui?.tuiId == expectedTuiIDs.first)
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

  @Test("Preview bootstrap auto-selects the declared ready session")
  func previewBootstrapAutoSelectsDeclaredReadySession() async {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: PreviewHarnessClient())
    )

    await store.bootstrapIfNeeded()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.sessions == [PreviewFixtures.summary])
    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession == PreviewFixtures.detail)
    #expect(store.timeline == PreviewFixtures.timeline)
  }

  @Test("Dashboard landing preview bootstraps without auto-selecting a session")
  func dashboardLandingPreviewBootstrapsWithoutAutoSelectingSession() async {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(
        client: PreviewHarnessClient(
          fixtures: .dashboardLanding,
          isLaunchAgentInstalled: true
        )
      )
    )

    await store.bootstrapIfNeeded()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.sessions == [PreviewFixtures.summary])
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
  }

  @Test("Task drop preview queues work on a busy worker")
  func taskDropPreviewQueuesWorkOnBusyWorker() async throws {
    let client = PreviewHarnessClient(
      fixtures: .taskDrop,
      isLaunchAgentInstalled: true
    )

    let detail = try await client.dropTask(
      sessionID: PreviewFixtures.taskDropSummary.sessionId,
      taskID: PreviewFixtures.taskDropTask.taskId,
      request: TaskDropRequest(
        actor: "leader-claude",
        target: .agent(agentId: "worker-codex"),
        queuePolicy: .locked
      )
    )

    let task = try #require(
      detail.tasks.first { $0.taskId == PreviewFixtures.taskDropTask.taskId }
    )
    #expect(task.assignedTo == "worker-codex")
    #expect(task.isQueuedForWorker)
    #expect(task.queuePolicy == .locked)
    #expect(task.queuedAt != nil)
    #expect(task.status == .open)

    let agent = try #require(detail.agents.first { $0.agentId == "worker-codex" })
    #expect(agent.currentTaskId == "task-ui")
    #expect(detail.session.metrics.openTaskCount == 1)
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

  @Test("Empty preview daemon auto-registers and connects during bootstrap")
  func emptyPreviewDaemonTransitionsOnlineAfterStart() async {
    let store = HarnessMonitorStore(daemonController: PreviewDaemonController(mode: .empty))

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(store.daemonStatus?.launchAgent.installed == true)
    #expect(store.sessions.isEmpty)
    #expect(store.health?.status == "ok")
  }
}
