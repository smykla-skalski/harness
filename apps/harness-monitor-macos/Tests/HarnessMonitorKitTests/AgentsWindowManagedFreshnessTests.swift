import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Agents window managed freshness gate")
@MainActor
struct AgentsWindowManagedFreshnessTests {
  @Test("Keeps stale active terminals hidden until the managed refresh succeeds")
  func keepsActiveTerminalHiddenUntilRefreshSucceeds() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSession = SessionDetail(
      session: PreviewFixtures.detail.session,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    store.selectedAgentTuis = [makeTuiSnapshot(status: .running)]

    let view = AgentsWindowView(store: store)

    #expect(view.displayState.sortedAgentTuis.isEmpty)

    view.refreshDisplayState()
    #expect(view.displayState.sortedAgentTuis.isEmpty)

    view.viewModel.hasFreshManagedAgentTuis = true
    view.refreshDisplayState()
    #expect(view.displayState.sortedAgentTuis.map(\.tuiId) == ["agent-tui-1"])
  }

  @Test("Workspace refresh state ignores volatile terminal screen text")
  func workspaceRefreshStateIgnoresVolatileTerminalScreenText() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSession = SessionDetail(
      session: PreviewFixtures.detail.session,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let initialTui = makeTuiSnapshot(status: .running, text: "first")
    store.selectedAgentTuis = [initialTui]
    store.selectedAgentTui = initialTui

    let view = AgentsWindowView(store: store)
    view.viewModel.hasFreshManagedAgentTuis = true
    view.viewModel.selection = .terminal(
      sessionID: initialTui.sessionId,
      terminalID: initialTui.tuiId
    )
    view.refreshDisplayState()
    let initialState = view.workspaceRefreshState

    let updatedTui = makeTuiSnapshot(
      status: .running,
      text: "second",
      updatedAt: "2026-04-30T12:02:00Z"
    )
    store.selectedAgentTuis = [updatedTui]
    store.selectedAgentTui = updatedTui

    #expect(view.workspaceRefreshState == initialState)
    #expect(view.selectedSessionTui?.screen.text == "second")
  }

  @Test("Workspace refresh state tracks terminal chrome changes")
  func workspaceRefreshStateTracksTerminalChromeChanges() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSession = SessionDetail(
      session: PreviewFixtures.detail.session,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let initialTui = makeTuiSnapshot(status: .running)
    store.selectedAgentTuis = [initialTui]
    store.selectedAgentTui = initialTui

    let view = AgentsWindowView(store: store)
    view.viewModel.hasFreshManagedAgentTuis = true
    view.refreshDisplayState()
    let initialState = view.workspaceRefreshState

    let updatedTui = makeTuiSnapshot(status: .exited)
    store.selectedAgentTuis = [updatedTui]
    store.selectedAgentTui = updatedTui

    #expect(view.workspaceRefreshState != initialState)
  }

  private func makeTuiSnapshot(
    status: AgentTuiStatus,
    text: String = "ready",
    updatedAt: String = "2026-04-30T12:01:00Z"
  ) -> AgentTuiSnapshot {
    AgentTuiSnapshot(
      tuiId: "agent-tui-1",
      sessionId: PreviewFixtures.summary.sessionId,
      agentId: "agent-1",
      runtime: "codex",
      status: status,
      argv: ["codex"],
      projectDir: "/tmp/fixture",
      size: AgentTuiSize(rows: 24, cols: 80),
      screen: AgentTuiScreenSnapshot(
        rows: 24,
        cols: 80,
        cursorRow: 0,
        cursorCol: 0,
        text: text
      ),
      transcriptPath: "/tmp/agent-tui-1.log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: "2026-04-30T12:00:00Z",
      updatedAt: updatedAt
    )
  }
}
