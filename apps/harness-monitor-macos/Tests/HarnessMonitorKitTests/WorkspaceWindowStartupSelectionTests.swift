import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Workspace window startup selection")
@MainActor
struct WorkspaceWindowStartupSelectionTests {
  @Test("Pending workspace selection wins over a stale supervisor-selected decision")
  func pendingWorkspaceSelectionWins() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let decision = makeDecision(id: "decision-startup-1", sessionID: "sess-startup-1")
    store.supervisorOpenDecisions = [decision]
    store.supervisorSelectedDecisionID = decision.id
    store.requestWorkspaceSelection(.decisions(sessionID: decision.sessionID))

    let view = WorkspaceWindowView(store: store)
    await view.resolveInitialWorkspaceSelection()

    #expect(view.viewModel.selection == .decisions(sessionID: decision.sessionID))
    #expect(store.consumePendingWorkspaceSelection() == nil)
  }

  @Test("Explicit decision requests still restore on startup")
  func explicitDecisionRequestRestoresOnStartup() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let decision = makeDecision(id: "decision-startup-2", sessionID: "sess-startup-2")
    store.supervisorOpenDecisions = [decision]
    store.supervisorSelectedDecisionID = decision.id
    store.requestWorkspaceDecisionSelection(decisionID: decision.id)

    let view = WorkspaceWindowView(store: store)
    await view.resolveInitialWorkspaceSelection()

    #expect(
      view.viewModel.selection
        == .decision(sessionID: decision.sessionID, decisionID: decision.id)
    )
  }

  @Test("Pending create entry points override a stored workspace route on reopen")
  func pendingCreateEntryPointOverridesStoredRoute() async {
    WorkspaceSelectionDefaults.write(
      .decision(sessionID: "sess-stored", decisionID: "decision-stored")
    )
    defer { WorkspaceSelectionDefaults.clear() }

    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let view = WorkspaceWindowView(store: store)

    store.requestWorkspaceCreateEntryPoint(.agent, sessionID: "sess-current")
    await view.resolveInitialWorkspaceSelection()

    #expect(view.viewModel.selection == .create)
    #expect(view.viewModel.createMode == .terminal)
    #expect(view.viewModel.createSessionID == "sess-current")
  }

  @Test("Workspace init keeps pending create requests for mounted state")
  func initKeepsPendingCreateRequestForMountedState() async {
    WorkspaceSelectionDefaults.write(
      .agent(sessionID: "sess-stored", agentID: "agent-stored")
    )
    defer { WorkspaceSelectionDefaults.clear() }

    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.requestWorkspaceCreateEntryPoint(.agent, sessionID: "sess-current")

    let view = WorkspaceWindowView(store: store)

    #expect(store.pendingWorkspaceSelection == .create)

    await view.resolveInitialWorkspaceSelection()

    #expect(store.pendingWorkspaceSelection == nil)
    #expect(view.viewModel.selection == .create)
    #expect(view.viewModel.createMode == .terminal)
    #expect(view.viewModel.createSessionID == "sess-current")
  }

  @Test("Preview create preset seeds ACP leader state")
  func previewCreatePresetSeedsAcpLeaderState() {
    let preset = WorkspaceWindowView.previewCreatePreset(
      environment: [WorkspacePreviewCreatePreset.environmentKey: "acp-leader-copilot"]
    )
    let viewModel = WorkspaceWindowView.ViewModel(selection: .create)

    #expect(preset == .acpLeaderCopilot)
    if let preset {
      WorkspaceWindowView.applyPreviewCreatePreset(preset, to: viewModel)
    }

    #expect(viewModel.createMode == .terminal)
    #expect(viewModel.selectedLaunchSelection == .acp("copilot"))
    #expect(viewModel.runtime == .copilot)
    #expect(viewModel.selectedRole == .leader)
    #expect(viewModel.selectedAcpFallbackRole == .observer)
  }

  @Test("Preview create preset blocks saved launch preset restore")
  func previewCreatePresetBlocksSavedLaunchPresetRestore() {
    #expect(
      !WorkspaceWindowView.shouldRestoreSavedLaunchPreset(
        environment: [WorkspacePreviewCreatePreset.environmentKey: "acp-leader-copilot"]
      )
    )
    #expect(WorkspaceWindowView.shouldRestoreSavedLaunchPreset(environment: [:]))
  }

  @Test("Stale supervisor-selected decisions do not hijack manual workspace open")
  func staleSupervisorSelectedDecisionDoesNotHijackManualOpen() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let decision = makeDecision(id: "decision-startup-3", sessionID: "sess-startup-3")
    store.supervisorOpenDecisions = [decision]
    store.supervisorSelectedDecisionID = decision.id

    let view = WorkspaceWindowView(store: store)
    await view.resolveInitialWorkspaceSelection()

    #expect(view.viewModel.selection == .create)
  }

  @Test("Stored workspace routes with unknown sessions are ignored once sessions are loaded")
  func storedWorkspaceRouteWithUnknownSessionIsIgnored() async {
    WorkspaceSelectionDefaults.write(
      .agent(sessionID: "sess1234", agentID: "agent-stored")
    )
    defer { WorkspaceSelectionDefaults.clear() }

    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.sessionIndex.sessions = [makeSummary(sessionID: "nod8ccog")]

    let view = WorkspaceWindowView(store: store)
    await view.resolveInitialWorkspaceSelection()

    #expect(view.viewModel.selection == .create)
    #expect(WorkspaceSelectionDefaults.read() == .create)
  }

  @Test("Stored workspace agent routes are repaired after live data invalidates them")
  func storedWorkspaceAgentRouteRepairsAfterRefresh() async {
    WorkspaceSelectionDefaults.write(
      .agent(sessionID: "sess1234", agentID: "worker-codex")
    )
    defer { WorkspaceSelectionDefaults.clear() }

    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let restoredView = WorkspaceWindowView(store: store)
    await restoredView.resolveInitialWorkspaceSelection()

    #expect(
      restoredView.viewModel.selection == .agent(sessionID: "sess1234", agentID: "worker-codex")
    )

    let liveSummary = makeSummary(sessionID: "zqykayai")
    store.sessionIndex.sessions = [liveSummary]
    store.selectedSessionID = liveSummary.sessionId
    store.selectedSession = SessionDetail(
      session: liveSummary,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )

    restoredView.refreshWorkspaceAfterDataChange()
    await Task.yield()

    #expect(restoredView.viewModel.selection == .create)
    #expect(WorkspaceSelectionDefaults.read() == .create)
  }

  @Test("Preview launch mode uses a separate workspace selection defaults key")
  func previewLaunchModeUsesSeparateWorkspaceSelectionDefaultsKey() {
    let suiteName = "WorkspaceSelectionDefaultsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let selection = WorkspaceSelection.agent(sessionID: "sess1234", agentID: "worker-codex")

    WorkspaceSelectionDefaults.write(
      selection,
      environment: [HarnessMonitorLaunchMode.environmentKey: "preview"],
      defaults: defaults
    )

    #expect(
      WorkspaceSelectionDefaults.read(
        environment: [HarnessMonitorLaunchMode.environmentKey: "preview"],
        defaults: defaults
      ) == selection
    )
    #expect(
      WorkspaceSelectionDefaults.read(
        environment: [HarnessMonitorLaunchMode.environmentKey: "live"],
        defaults: defaults
      ) == nil
    )
  }

  @Test("Scene restoration is disabled outside live launch mode")
  func sceneRestorationIsDisabledOutsideLiveLaunchMode() {
    #expect(
      ContentSceneRestorationBridge.allowsPersistentSceneRestoration(
        environment: [HarnessMonitorLaunchMode.environmentKey: "live"]
      )
    )
    #expect(
      !ContentSceneRestorationBridge.allowsPersistentSceneRestoration(
        environment: [HarnessMonitorLaunchMode.environmentKey: "preview"]
      )
    )
  }

  private func makeDecision(id: String, sessionID: String) -> Decision {
    let decision = Decision(
      id: id,
      severity: .critical,
      ruleID: "daemon-disconnect",
      sessionID: sessionID,
      agentID: nil,
      taskID: nil,
      summary: "Workspace startup routing regression fixture.",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    decision.createdAt = .distantPast
    return decision
  }

  private func makeSummary(sessionID: String) -> SessionSummary {
    SessionSummary(
      projectId: "project-\(sessionID)",
      projectName: "harness",
      projectDir: "/Users/example/Projects/harness",
      contextRoot: "/Users/example/Library/Application Support/harness/sessions/harness",
      sessionId: sessionID,
      worktreePath: "/Users/example/Projects/harness-\(sessionID)",
      sharedPath: "/Users/example/Projects/harness-\(sessionID)/shared",
      originPath: "/Users/example/Projects/harness",
      branchRef: "harness/\(sessionID)",
      title: "Session \(sessionID)",
      context: "Workspace startup routing fixture",
      status: .active,
      createdAt: "2026-03-28T14:05:00Z",
      updatedAt: "2026-03-28T14:18:00Z",
      lastActivityAt: "2026-03-28T14:18:00Z",
      leaderId: "leader-\(sessionID)",
      observeId: "observe-\(sessionID)",
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 1,
        activeAgentCount: 1,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      ),
    )
  }
}
