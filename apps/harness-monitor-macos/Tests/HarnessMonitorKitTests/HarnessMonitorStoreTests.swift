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
    let controller = RecordingDaemonController(launchAgentInstalled: false)
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
    #expect(store.currentFailureFeedbackMessage != nil)
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

    #expect(store.currentFailureFeedbackMessage != nil)
    #expect(store.isBusy == false)
  }

  @Test("Refresh with no client triggers bootstrap")
  func refreshWithNoClientTriggersBootstrap() async {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.refresh()

    #expect(store.currentFailureFeedbackMessage != nil)
  }

  @Test("Refresh failure tears down active background streams")
  func refreshFailureTearsDownActiveBackgroundStreams() async {
    let store = await makeBootstrappedStore(client: RecordingHarnessClient())
    defer { store.stopAllStreams() }

    await store.selectSession(PreviewFixtures.summary.sessionId)
    #expect(store.globalStreamTask != nil)
    #expect(store.sessionStreamTask != nil)

    let refreshError = HarnessMonitorAPIError.server(code: 500, message: "refresh failed")
    await store.refresh(
      using: FailingHarnessClient(error: refreshError),
      preserveSelection: true
    )

    #expect(store.globalStreamTask == nil)
    #expect(store.sessionStreamTask == nil)
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
      store.currentFailureFeedbackMessage
        == DaemonControlError.commandFailed("install failed").localizedDescription
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
      store.currentFailureFeedbackMessage
        == DaemonControlError.commandFailed("remove failed").localizedDescription
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

  @Test("Toolbar counts only session-backed projects and worktrees")
  func toolbarCountsOnlySessionBackedProjectsAndWorktrees() async {
    let store = await makeBootstrappedStore()

    guard let status = store.daemonStatus else {
      Issue.record("expected daemonStatus after bootstrap")
      return
    }
    store.daemonStatus = DaemonStatusReport(
      manifest: status.manifest,
      launchAgent: status.launchAgent,
      projectCount: 42,
      worktreeCount: 5,
      sessionCount: 6,
      diagnostics: status.diagnostics
    )

    let project1 = ProjectSummary(
      projectId: "project-a",
      name: "harness",
      projectDir: "/Users/example/Projects/harness",
      contextRoot: "/Users/example/Library/Application Support/harness/projects/project-a",
      activeSessionCount: 2,
      totalSessionCount: 2,
      worktrees: [
        WorktreeSummary(
          checkoutId: "checkout-a",
          name: "session-title",
          checkoutRoot: "/Users/example/Projects/harness/.claude/worktrees/session-title",
          contextRoot: "/Users/example/Library/Application Support/harness/projects/checkout-a",
          activeSessionCount: 2,
          totalSessionCount: 2
        )
      ]
    )
    let project2 = ProjectSummary(
      projectId: "project-b",
      name: "kuma",
      projectDir: "/Users/example/Projects/kuma",
      contextRoot: "/Users/example/Library/Application Support/harness/projects/project-b",
      activeSessionCount: 1,
      totalSessionCount: 1,
      worktrees: [
        WorktreeSummary(
          checkoutId: "checkout-b",
          name: "fix-motb",
          checkoutRoot: "/Users/example/Projects/kuma/.claude/worktrees/fix-motb",
          contextRoot: "/Users/example/Library/Application Support/harness/projects/checkout-b",
          activeSessionCount: 1,
          totalSessionCount: 1
        )
      ]
    )
    let orphanProject = ProjectSummary(
      projectId: "project-orphan",
      name: "scratch",
      projectDir: "/Users/example/Projects/scratch",
      contextRoot: "/Users/example/Library/Application Support/harness/projects/project-orphan",
      activeSessionCount: 0,
      totalSessionCount: 0,
      worktrees: [
        WorktreeSummary(
          checkoutId: "checkout-orphan",
          name: "old-worktree",
          checkoutRoot: "/Users/example/Projects/scratch/.claude/worktrees/old-worktree",
          contextRoot:
            "/Users/example/Library/Application Support/harness/projects/checkout-orphan",
          activeSessionCount: 0,
          totalSessionCount: 0
        )
      ]
    )
    let session1 = SessionSummary(
      projectId: project1.projectId,
      projectName: project1.name,
      projectDir: project1.projectDir,
      contextRoot: project1.contextRoot,
      checkoutId: "checkout-a",
      checkoutRoot: "/Users/example/Projects/harness/.claude/worktrees/session-title",
      isWorktree: true,
      worktreeName: "session-title",
      sessionId: "sess-a-1",
      title: "Primary",
      context: "Primary",
      status: .active,
      createdAt: "2026-03-28T14:00:00Z",
      updatedAt: "2026-03-28T14:18:00Z",
      lastActivityAt: "2026-03-28T14:18:00Z",
      leaderId: "leader-a",
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 2,
        activeAgentCount: 2,
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      )
    )
    let session2 = SessionSummary(
      projectId: project1.projectId,
      projectName: project1.name,
      projectDir: project1.projectDir,
      contextRoot: project1.contextRoot,
      checkoutId: "checkout-a",
      checkoutRoot: "/Users/example/Projects/harness/.claude/worktrees/session-title",
      isWorktree: true,
      worktreeName: "session-title",
      sessionId: "sess-a-2",
      title: "Secondary",
      context: "Secondary",
      status: .active,
      createdAt: "2026-03-28T14:02:00Z",
      updatedAt: "2026-03-28T14:20:00Z",
      lastActivityAt: "2026-03-28T14:20:00Z",
      leaderId: "leader-a",
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 2,
        activeAgentCount: 1,
        openTaskCount: 2,
        inProgressTaskCount: 0,
        blockedTaskCount: 1,
        completedTaskCount: 0
      )
    )
    let session3 = SessionSummary(
      projectId: project2.projectId,
      projectName: project2.name,
      projectDir: project2.projectDir,
      contextRoot: project2.contextRoot,
      checkoutId: "checkout-b",
      checkoutRoot: "/Users/example/Projects/kuma/.claude/worktrees/fix-motb",
      isWorktree: true,
      worktreeName: "fix-motb",
      sessionId: "sess-b-1",
      title: "Kuma",
      context: "Kuma",
      status: .active,
      createdAt: "2026-03-28T14:04:00Z",
      updatedAt: "2026-03-28T14:22:00Z",
      lastActivityAt: "2026-03-28T14:22:00Z",
      leaderId: "leader-b",
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 1,
        activeAgentCount: 1,
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      )
    )
    store.applySessionIndexSnapshot(
      projects: [project1, project2, orphanProject],
      sessions: [session1, session2, session3]
    )

    #expect(store.contentUI.toolbar.toolbarMetrics.projectCount == 2)
    #expect(store.contentUI.toolbar.toolbarMetrics.worktreeCount == 2)
    #expect(store.contentUI.toolbar.toolbarMetrics.sessionCount == 3)
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
