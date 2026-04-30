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

  private func makeTuiSnapshot(status: AgentTuiStatus) -> AgentTuiSnapshot {
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
        text: "ready"
      ),
      transcriptPath: "/tmp/agent-tui-1.log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: "2026-04-30T12:00:00Z",
      updatedAt: "2026-04-30T12:01:00Z"
    )
  }
}
