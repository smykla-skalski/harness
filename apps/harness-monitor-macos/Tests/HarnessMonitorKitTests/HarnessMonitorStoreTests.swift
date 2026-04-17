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

  @Test("Selecting a session requests the full detail payload")
  func selectSessionRequestsFullDetail() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(client.sessionDetailScopes(for: PreviewFixtures.summary.sessionId) == [nil])
    #expect(store.selectedSession?.signals == PreviewFixtures.signals)
    #expect(store.isExtensionsLoading == false)
  }

  @Test("Grouped sessions filter by search text and status")
  func groupedSessionsFiltersBySearchTextAndStatus() async {
    let store = await makeBootstrappedStore()

    store.searchText = "cockpit"
    store.sessionFilter = .active

    #expect(store.groupedSessions.map(\.project.projectId) == [PreviewFixtures.summary.projectId])
    #expect(
      store.groupedSessions.first?.sessionIDs == [PreviewFixtures.summary.sessionId]
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
    #expect(store.groupedSessions.flatMap(\.sessionIDs) == ["sess-blocked"])
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
    store.flushPendingSearchRebuild()
    store.sessionFilter = .all

    #expect(store.groupedSessions.flatMap(\.sessionIDs) == ["sess-a"])

    store.resetFilters()

    #expect(store.searchText.isEmpty)
    #expect(store.sessionFilter == .all)
    #expect(store.sessionFocusFilter == .all)
    #expect(store.groupedSessions.flatMap(\.sessionIDs) == ["sess-a", "sess-b"])
  }

  @Test("Installing the launch agent refreshes daemon diagnostics")
  func installLaunchAgentRefreshesDaemonDiagnostics() async {
    let controller = RecordingDaemonController(
      launchAgentInstalled: false, registrationState: .requiresApproval)
    let store = HarnessMonitorStore(daemonController: controller)

    await store.bootstrap()
    #expect(store.daemonStatus?.launchAgent.installed == false)

    await store.installLaunchAgent()

    #expect(store.daemonStatus?.launchAgent.installed == true)
    #expect(store.daemonStatus?.launchAgent.loaded == true)
    #expect(store.daemonStatus?.launchAgent.pid == 4_242)
    #expect(store.daemonStatus?.diagnostics.lastEvent?.message == "launch agent installed")
    #expect(store.currentSuccessFeedbackMessage == "Install launch agent")
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
    #expect(store.currentSuccessFeedbackMessage == "Remove launch agent")
  }

  @Test("Success feedback auto-dismisses from the store")
  func successFeedbackAutoDismissesFromTheStore() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.configureUITestBehavior(
      successFeedbackDismissDelay: .milliseconds(10),
      failureFeedbackDismissDelay: .milliseconds(10)
    )

    store.presentSuccessFeedback("Install launch agent")
    #expect(store.currentSuccessFeedbackMessage == "Install launch agent")

    try? await Task.sleep(for: .milliseconds(40))

    #expect(store.currentSuccessFeedbackMessage == nil)
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

  @Test("Cached catalog does not mark selected-session availability stale")
  func cachedCatalogDoesNotMarkSelectedSessionAvailabilityStale() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    store.connectionState = .online
    store.isShowingCachedCatalog = true
    store.isShowingCachedSelectedSession = false
    store.persistedSessionCount = 1

    #expect(store.sessionCatalogIsEstimated)
    #expect(store.sessionDataAvailability == .live)
  }

  @Test("Leaderless summaries do not render as plain active")
  func leaderlessSummariesDoNotRenderAsPlainActive() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let summary = makeSession(
      .init(
        sessionId: "sess-leaderless",
        context: "Leaderless review lane",
        status: .active,
        leaderId: nil,
        observeId: nil,
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )

    let presentation = store.sessionSummaryPresentation(for: summary)

    #expect(presentation.statusText == "Leaderless")
    #expect(presentation.statusTone == .caution)
    #expect(presentation.agentStat.symbolName == "person.2")
    #expect(presentation.agentStat.valueText == "2")
    #expect(presentation.agentStat.helpText == "2 known")
    #expect(presentation.isEstimated == false)
  }

  @Test("Cached catalog summaries avoid live agent phrasing")
  func cachedCatalogSummariesAvoidLiveAgentPhrasing() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.connectionState = .connecting
    store.isShowingCachedCatalog = true
    store.persistedSessionCount = 1

    let summary = makeSession(
      .init(
        sessionId: "sess-cached",
        context: "Cached reconnect lane",
        status: .active,
        leaderId: "leader-cached",
        observeId: nil,
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )

    let presentation = store.sessionSummaryPresentation(for: summary)

    #expect(presentation.statusText == "Active")
    #expect(presentation.statusTone == .secondary)
    #expect(presentation.isEstimated)
    #expect(presentation.agentStat.symbolName == "person.2")
    #expect(presentation.agentStat.valueText == "2")
    #expect(presentation.agentStat.helpText == "2 known")
  }

  @Test("Live active summaries use filled agent stat icon")
  func liveActiveSummariesUseFilledAgentStatIcon() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let summary = makeSession(
      .init(
        sessionId: "sess-live",
        context: "Live active lane",
        status: .active,
        leaderId: "leader-live",
        observeId: "observe-live",
        openTaskCount: 1,
        inProgressTaskCount: 2,
        blockedTaskCount: 0,
        activeAgentCount: 3
      )
    )

    let presentation = store.sessionSummaryPresentation(for: summary)

    #expect(presentation.agentStat.symbolName == "person.2.fill")
    #expect(presentation.agentStat.valueText == "3")
    #expect(presentation.agentStat.helpText == "3 active")
  }

  @Test("Task stat uses moving icon and help text")
  func taskStatUsesMovingIconAndHelpText() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let summary = makeSession(
      .init(
        sessionId: "sess-tasks",
        context: "Moving task lane",
        status: .active,
        leaderId: "leader-tasks",
        observeId: "observe-tasks",
        openTaskCount: 1,
        inProgressTaskCount: 4,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )

    let presentation = store.sessionSummaryPresentation(for: summary)

    #expect(presentation.taskStat.symbolName == "arrow.triangle.2.circlepath")
    #expect(presentation.taskStat.valueText == "4")
    #expect(presentation.taskStat.helpText == "4 moving")
  }

  @Test("Agent activity presentation never shows ready for disconnected or cached agents")
  func agentActivityPresentationNeverShowsReadyForDisconnectedOrCachedAgents() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities

    let disconnectedAgent = AgentRegistration(
      agentId: "worker-disconnected",
      name: "Disconnected Worker",
      runtime: "codex",
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: .disconnected,
      agentSessionId: "worker-disconnected-session",
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )

    let activeAgent = AgentRegistration(
      agentId: "worker-active",
      name: "Active Worker",
      runtime: "codex",
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: .active,
      agentSessionId: "worker-active-session",
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )

    let disconnectedPresentation = store.agentActivityPresentation(
      for: disconnectedAgent,
      queuedTasks: [],
      isSelectedSessionLive: true
    )
    let cachedPresentation = store.agentActivityPresentation(
      for: activeAgent,
      queuedTasks: [],
      isSelectedSessionLive: false
    )

    #expect(disconnectedPresentation.label == "Disconnected")
    #expect(cachedPresentation.label == "Snapshot")
  }
}
