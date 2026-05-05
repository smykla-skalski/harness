import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Workspace ACP stale session routing")
@MainActor
struct WorkspaceAcpStaleSessionRoutingTests {
  @Test("Create resolver prefers selected session over stale route and cached anchor")
  func resolvedCreateSessionIDPrefersSelectedSessionOverStaleAnchors() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.sessionIndex.sessions = [
      makeRoutingSummary(sessionID: "nod8ccog"),
      makeRoutingSummary(sessionID: "zqykayai"),
    ]
    store.selectedSessionID = "zqykayai"
    let view = WorkspaceWindowView(store: store)
    view.viewModel.selection = .agent(sessionID: "nod8ccog", agentID: "gemini-old")
    view.viewModel.createSessionID = "nod8ccog"

    #expect(view.resolvedCreateSessionID == "zqykayai")
  }

  @Test("Create resolver keeps selected session before catalog refresh")
  func resolvedCreateSessionIDPrefersSelectedSessionBeforeCatalogRefresh() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.sessionIndex.sessions = [makeRoutingSummary(sessionID: "nod8ccog")]
    store.selectedSessionID = "zqykayai"
    let view = WorkspaceWindowView(store: store)
    view.viewModel.selection = .agent(sessionID: "nod8ccog", agentID: "gemini-old")
    view.viewModel.createSessionID = "nod8ccog"

    #expect(view.resolvedCreateSessionID == "zqykayai")
  }

  @Test("Create resolver drops stale route and cached anchor when no active session is selected")
  func resolvedCreateSessionIDDropsStaleAnchorsWithoutSelectedSession() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.sessionIndex.sessions = [makeRoutingSummary(sessionID: "zqykayai")]
    store.selectedSessionID = nil
    let view = WorkspaceWindowView(store: store)
    view.viewModel.selection = .agent(sessionID: "nod8ccog", agentID: "gemini-old")
    view.viewModel.createSessionID = "nod8ccog"

    #expect(view.resolvedCreateSessionID == nil)
  }

  @Test("Create selection does not reseat a deleted route anchor")
  func createSelectionDropsStaleMissingSelectedSession() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.sessionIndex.sessions = [makeRoutingSummary(sessionID: "zqykayai")]
    store.selectedSessionID = nil
    let view = WorkspaceWindowView(store: store)
    view.viewModel.selection = .create
    view.viewModel.createSessionID = "nod8ccog"

    await view.handleSelectionChange(
      from: .agent(sessionID: "nod8ccog", agentID: "gemini-old"),
      to: .create
    )

    #expect(view.viewModel.createSessionID == nil)
    #expect(store.selectedSessionID == nil)
  }

  @Test("ACP start from create does not call daemon with stale cached anchor")
  func acpStartFromCreateBlocksStaleCachedAnchor() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let view = WorkspaceWindowView(store: store)
    store.toast.dismissAll()
    store.sessionIndex.sessions = [makeRoutingSummary(sessionID: "zqykayai")]
    store.selectedSessionID = nil
    view.viewModel.selection = .create
    view.viewModel.createSessionID = "nod8ccog"
    view.viewModel.selectedLaunchSelection = .acp("copilot")
    view.viewModel.availableAcpAgents = [
      AcpAgentDescriptor(
        id: "copilot",
        displayName: "GitHub Copilot",
        capabilities: ["fs.read", "terminal.spawn"],
        launchCommand: "copilot",
        launchArgs: ["agent", "acp"],
        envPassthrough: [],
        doctorProbe: AcpDoctorProbe(command: "copilot", args: ["--version"])
      )
    ]

    let didHandleAcp = await view.startAcpAgentIfSelected()

    #expect(didHandleAcp)
    #expect(client.recordedCalls() == [])
    #expect(store.currentFailureFeedbackMessage?.contains("No session is selected") == true)
    #expect(store.selectedSessionID == nil)
  }
}

private func makeRoutingSummary(sessionID: String) -> SessionSummary {
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
    context: "Workspace ACP stale routing fixture",
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
