import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreTests {
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

  @Test("Request end confirmation uses the control-plane actor")
  func requestEndConfirmationUsesControlPlaneActor() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.requestEndSelectedSessionConfirmation()

    #expect(
      store.pendingConfirmation
        == .endSession(
          sessionID: PreviewFixtures.summary.sessionId,
          actorID: "harness-app"
        )
    )
  }

  @Test("Sidebar summary counts only session-backed projects and worktrees")
  func sidebarSummaryCountsOnlySessionBackedProjectsAndWorktrees() async {
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

    let (projects, sessions) = makeToolbarCountFixtures()
    store.applySessionIndexSnapshot(projects: projects, sessions: sessions)

    // Two distinct origin worktrees back the 3 sessions across the active projects.
    #expect(store.sidebarUI.projectCount == 2)
    #expect(store.sidebarUI.worktreeCount == 2)
    #expect(store.sidebarUI.sessionCount == 3)
  }

  private func makeToolbarCountFixtures() -> (
    projects: [ProjectSummary],
    sessions: [SessionSummary]
  ) {
    let ctxRoot = "/Users/example/Library/Application Support/harness/projects"
    let project1 = ProjectSummary(
      projectId: "project-a",
      name: "harness",
      projectDir: "/Users/example/Projects/harness",
      contextRoot: "\(ctxRoot)/project-a",
      activeSessionCount: 2,
      totalSessionCount: 2,
      worktrees: [
        WorktreeSummary(
          checkoutId: "checkout-a",
          name: "session-title",
          checkoutRoot: "/Users/example/Projects/harness/.claude/worktrees/session-title",
          contextRoot: "\(ctxRoot)/checkout-a",
          activeSessionCount: 2,
          totalSessionCount: 2
        )
      ]
    )
    let project2 = ProjectSummary(
      projectId: "project-b",
      name: "kuma",
      projectDir: "/Users/example/Projects/kuma",
      contextRoot: "\(ctxRoot)/project-b",
      activeSessionCount: 1,
      totalSessionCount: 1,
      worktrees: [
        WorktreeSummary(
          checkoutId: "checkout-b",
          name: "fix-motb",
          checkoutRoot: "/Users/example/Projects/kuma/.claude/worktrees/fix-motb",
          contextRoot: "\(ctxRoot)/checkout-b",
          activeSessionCount: 1,
          totalSessionCount: 1
        )
      ]
    )
    let orphanProject = ProjectSummary(
      projectId: "project-orphan",
      name: "scratch",
      projectDir: "/Users/example/Projects/scratch",
      contextRoot: "\(ctxRoot)/project-orphan",
      activeSessionCount: 0,
      totalSessionCount: 0,
      worktrees: [
        WorktreeSummary(
          checkoutId: "checkout-orphan",
          name: "old-worktree",
          checkoutRoot: "/Users/example/Projects/scratch/.claude/worktrees/old-worktree",
          contextRoot: "\(ctxRoot)/checkout-orphan",
          activeSessionCount: 0,
          totalSessionCount: 0
        )
      ]
    )
    let sessions = makeToolbarCountSessions(project1: project1, project2: project2)
    return ([project1, project2, orphanProject], sessions)
  }

  private func makeToolbarCountSessions(
    project1: ProjectSummary,
    project2: ProjectSummary
  ) -> [SessionSummary] {
    let sessionsRoot = "/Users/example/Library/Application Support/harness/sessions"
    let session1 = SessionSummary(
      projectId: project1.projectId,
      projectName: project1.name,
      projectDir: project1.projectDir,
      contextRoot: "\(sessionsRoot)/harness",
      sessionId: "sessa001",
      worktreePath: "\(sessionsRoot)/harness/sessa001/workspace",
      sharedPath: "\(sessionsRoot)/harness/sessa001/memory",
      originPath: project1.worktrees.first?.checkoutRoot ?? project1.projectDir ?? "",
      branchRef: "harness/sessa001",
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
      contextRoot: "\(sessionsRoot)/harness",
      sessionId: "sessa002",
      worktreePath: "\(sessionsRoot)/harness/sessa002/workspace",
      sharedPath: "\(sessionsRoot)/harness/sessa002/memory",
      originPath: project1.worktrees.first?.checkoutRoot ?? project1.projectDir ?? "",
      branchRef: "harness/sessa002",
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
      contextRoot: "\(sessionsRoot)/kuma",
      sessionId: "sessb001",
      worktreePath: "\(sessionsRoot)/kuma/sessb001/workspace",
      sharedPath: "\(sessionsRoot)/kuma/sessb001/memory",
      originPath: project2.worktrees.first?.checkoutRoot ?? project2.projectDir ?? "",
      branchRef: "harness/sessb001",
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
    return [session1, session2, session3]
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
