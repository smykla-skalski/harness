import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store")
struct HarnessMonitorStoreTests {
  @Test("Bootstrap loads the dashboard data")
  func bootstrapLoadsDashboardData() async {
    let store = await makeBootstrappedStore()

    #expect(store.connectionState == .online)
    #expect(store.projects == PreviewFixtures.projects)
    #expect(store.sessions.map(\.sessionId) == [PreviewFixtures.summary.sessionId])
    #expect(store.health?.status == "ok")
    #expect(store.diagnostics?.recentEvents.first?.message == "daemon ready")
  }

  @Test("Selecting a session loads detail and timeline")
  func selectSessionLoadsDetailAndTimeline() async {
    let store = await makeBootstrappedStore()

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(store.selectedSession?.session.sessionId == PreviewFixtures.summary.sessionId)
    #expect(store.timeline == PreviewFixtures.timeline)
    #expect(store.actionActorID == PreviewFixtures.summary.leaderId)
  }

  @Test("Grouped sessions filter by search text and status")
  func groupedSessionsFiltersBySearchTextAndStatus() async {
    let store = await makeBootstrappedStore()

    store.searchText = "cockpit"
    store.sessionFilter = .active

    #expect(store.groupedSessions.map(\.project.projectId) == [PreviewFixtures.summary.projectId])
    #expect(
      store.groupedSessions.first?.sessions.map(\.sessionId) == [PreviewFixtures.summary.sessionId]
    )
  }

  @Test("Blocked focus filter narrows the session slice")
  func blockedFocusFilterNarrowsSessionSlice() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 3, activeSessionCount: 2)]

    var activeFixture = SessionFixture(
      sessionId: "sess-active",
      context: "Track live cockpit",
      status: .active,
      leaderId: "leader-claude",
      observeId: "observe-active",
      openTaskCount: 1,
      inProgressTaskCount: 1,
      blockedTaskCount: 0,
      activeAgentCount: 2
    )
    activeFixture.lastActivityAt = "2026-03-28T14:18:00Z"

    var blockedFixture = SessionFixture(
      sessionId: "sess-blocked",
      context: "Blocked review lane",
      status: .active,
      leaderId: "leader-claude",
      observeId: "observe-blocked",
      openTaskCount: 2,
      inProgressTaskCount: 1,
      blockedTaskCount: 1,
      activeAgentCount: 3
    )
    blockedFixture.lastActivityAt = "2026-03-28T14:19:00Z"

    var endedFixture = SessionFixture(
      sessionId: "sess-ended",
      context: "Archived cleanup lane",
      status: .ended,
      leaderId: "leader-claude",
      observeId: nil,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 0
    )
    endedFixture.lastActivityAt = "2026-03-28T14:10:00Z"

    store.sessions = [
      makeSession(activeFixture),
      makeSession(blockedFixture),
      makeSession(endedFixture),
    ]

    store.sessionFilter = .active
    #expect(store.sessionFilter == .active)

    store.sessionFocusFilter = .blocked
    #expect(store.sessionFocusFilter == .blocked)
    #expect(store.searchText.isEmpty)
    #expect(store.groupedSessions.flatMap(\.sessions).map(\.sessionId) == ["sess-blocked"])
  }

  @Test("Search matches across tokens and reset filters restores defaults")
  func searchMatchesAcrossTokensAndResetFiltersRestoresDefaults() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 2, activeSessionCount: 1)]
    store.sessions = [
      makeSession(
        .init(
          sessionId: "sess-a",
          context: "Harness Monitor cockpit workstream",
          status: .active,
          leaderId: "leader-alpha",
          observeId: "observe-a",
          openTaskCount: 1,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        )
      ),
      makeSession(
        .init(
          sessionId: "sess-b",
          context: "Other lane",
          status: .ended,
          leaderId: "leader-beta",
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      ),
    ]

    store.searchText = "harness leader-alpha"
    store.sessionFilter = .all

    #expect(store.groupedSessions.flatMap(\.sessions).map(\.sessionId) == ["sess-a"])

    store.resetFilters()

    #expect(store.searchText.isEmpty)
    #expect(store.sessionFilter == .active)
    #expect(store.sessionFocusFilter == .all)
    #expect(store.groupedSessions.flatMap(\.sessions).map(\.sessionId) == ["sess-a"])
  }

  @Test("Installing the launch agent refreshes daemon diagnostics")
  func installLaunchAgentRefreshesDaemonDiagnostics() async {
    let controller = RecordingDaemonController(launchAgentInstalled: false)
    let store = HarnessMonitorStore(daemonController: controller)

    await store.bootstrap()
    #expect(store.daemonStatus?.launchAgent.installed == false)

    await store.installLaunchAgent()

    #expect(store.daemonStatus?.launchAgent.installed == true)
    #expect(store.daemonStatus?.launchAgent.loaded == true)
    #expect(store.daemonStatus?.launchAgent.pid == 4_242)
    #expect(store.daemonStatus?.diagnostics.lastEvent?.message == "launch agent installed")
    #expect(store.lastAction == "Install launch agent")
  }

  @Test("Removing the launch agent refreshes daemon diagnostics")
  func removeLaunchAgentRefreshesDaemonDiagnostics() async {
    let controller = RecordingDaemonController(launchAgentInstalled: true)
    let store = HarnessMonitorStore(daemonController: controller)

    await store.bootstrap()
    #expect(store.daemonStatus?.launchAgent.installed == true)

    await store.removeLaunchAgent()

    #expect(store.daemonStatus?.launchAgent.installed == false)
    #expect(store.daemonStatus?.launchAgent.loaded == false)
    #expect(store.daemonStatus?.launchAgent.pid == nil)
    #expect(store.daemonStatus?.diagnostics.lastEvent?.message == "launch agent removed")
    #expect(store.lastAction == "Remove launch agent")
  }

  @Test("Last action auto-dismisses from the store")
  func lastActionAutoDismissesFromTheStore() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.lastActionDismissDelay = .milliseconds(10)

    store.showLastAction("Install launch agent")
    #expect(store.lastAction == "Install launch agent")

    try? await Task.sleep(for: .milliseconds(40))

    #expect(store.lastAction.isEmpty)
  }

  @Test("Reconnect refreshes health and status")
  func reconnectRefreshesHealthAndStatus() async {
    let store = await makeBootstrappedStore()

    store.health = nil
    store.daemonStatus = nil
    store.connectionState = .offline("stale")

    await store.reconnect()

    #expect(store.connectionState == .online)
    #expect(store.health?.status == "ok")
    #expect(store.daemonStatus?.diagnostics.databaseSizeBytes == 1_740_800)
    #expect(store.diagnostics?.workspace.databaseSizeBytes == 1_740_800)
  }

  @Test("Cached data status message reflects connection state")
  func cachedDataStatusMessageReflectsConnectionState() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    store.connectionState = .online
    #expect(
      store.cachedDataStatusMessage
        == "Showing cached data - live session detail is unavailable"
    )

    store.connectionState = .offline("daemon down")
    #expect(store.cachedDataStatusMessage == "Showing cached data - daemon is offline")
  }

  @Test("Refreshing diagnostics loads live daemon diagnostics")
  func refreshDiagnosticsLoadsLiveDaemonDiagnostics() async {
    let store = await makeBootstrappedStore()

    store.diagnostics = nil

    await store.refreshDiagnostics()

    #expect(store.diagnostics?.workspace.databaseSizeBytes == 1_740_800)
    #expect(store.diagnostics?.recentEvents.count == 1)
  }

  @Test("Bootstrap failure sets the offline state and error")
  func bootstrapFailureSetsOfflineStateAndError() async {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.harnessBinaryNotFound
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(
      store.connectionState
        == .offline(DaemonControlError.harnessBinaryNotFound.localizedDescription)
    )
    #expect(store.lastError != nil)
    #expect(store.health == nil)
  }

  @Test("Create task failure sets the last error")
  func createTaskFailureSetsLastError() async {
    let client = FailingHarnessClient()
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession("sess-1")

    await store.createTask(title: "broken", context: nil, severity: .high)

    #expect(store.lastError != nil)
    #expect(store.isBusy == false)
  }

  @Test("Refresh with no client triggers bootstrap")
  func refreshWithNoClientTriggersBootstrap() async {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.refresh()

    #expect(store.lastError != nil)
  }

  @Test("Manual refresh completes even when transport ping would stall")
  func manualRefreshCompletesWithoutTransportPing() async {
    let client = RecordingHarnessClient()
    client.configureDiagnosticsDelay(.milliseconds(80))
    client.configureTransportLatencyError(
      HarnessMonitorAPIError.server(code: 599, message: "ping stalled")
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.connectionProbeInterval = .seconds(30)

    await store.bootstrap()

    let refreshTask = Task {
      await store.refresh()
    }
    await Task.yield()

    #expect(store.isRefreshing)

    await refreshTask.value

    #expect(store.isRefreshing == false)
    #expect(store.connectionState == .online)
    #expect(store.health?.status == "ok")
    #expect(client.readCallCount(.transportLatency) == 0)

    store.stopAllStreams()
  }

  @Test("Install launch agent failure sets the last error")
  func installLaunchAgentFailureSetsLastError() async {
    let daemon = FailingDaemonController(
      actionError: DaemonControlError.commandFailed("install failed")
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.installLaunchAgent()

    #expect(
      store.lastError == DaemonControlError.commandFailed("install failed").localizedDescription
    )
    #expect(store.isBusy == false)
  }

  @Test("Remove launch agent failure sets the last error")
  func removeLaunchAgentFailureSetsLastError() async {
    let daemon = FailingDaemonController(
      actionError: DaemonControlError.commandFailed("remove failed")
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.removeLaunchAgent()

    #expect(
      store.lastError == DaemonControlError.commandFailed("remove failed").localizedDescription
    )
    #expect(store.isBusy == false)
  }

  @Test("Request end confirmation uses the resolved actor")
  func requestEndConfirmationUsesResolvedActor() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.requestEndSelectedSessionConfirmation()

    #expect(
      store.pendingConfirmation
        == .endSession(
          sessionID: PreviewFixtures.summary.sessionId,
          actorID: PreviewFixtures.agents[0].agentId
        )
    )
  }

  @Test("Confirm pending remove-agent action executes the mutation")
  func confirmPendingRemoveAgentExecutesMutation() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.requestRemoveAgentConfirmation(agentID: PreviewFixtures.agents[1].agentId)
    await store.confirmPendingAction()

    #expect(store.pendingConfirmation == nil)
    #expect(
      client.recordedCalls()
        == [
          .removeAgent(
            sessionID: PreviewFixtures.summary.sessionId,
            agentID: PreviewFixtures.agents[1].agentId,
            actor: PreviewFixtures.agents[0].agentId
          )
        ]
    )
  }
}
