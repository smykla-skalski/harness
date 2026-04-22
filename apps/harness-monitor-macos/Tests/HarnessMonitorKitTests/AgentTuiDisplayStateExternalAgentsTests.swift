import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Agents window external-agents derivation")
@MainActor
struct AgentTuiDisplayStateExternalAgentsTests {
  @Test("Returns empty when no session is selected")
  func emptyWhenNoSession() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let state = AgentTuiWindowView.AgentTuiDisplayState(store: store)
    #expect(state.externalAgents.isEmpty)
  }

  @Test("Returns all session agents when no TUI snapshots are present")
  func returnsAllAgentsWhenNoTuis() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSession = makeSessionDetail(agents: [
      makeAgent(id: "alpha", name: "Alpha"),
      makeAgent(id: "bravo", name: "Bravo"),
    ])
    let state = AgentTuiWindowView.AgentTuiDisplayState(store: store)
    #expect(state.externalAgents.map(\.agentId) == ["alpha", "bravo"])
  }

  @Test("Includes agents even when a matching TUI snapshot exists")
  func includesTuiBackedAgents() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSession = makeSessionDetail(agents: [
      makeAgent(id: "alpha", name: "Alpha"),
      makeAgent(id: "bravo", name: "Bravo"),
      makeAgent(id: "charlie", name: "Charlie"),
    ])
    store.selectedAgentTuis = [makeTuiSnapshot(tuiID: "tui-bravo", agentID: "bravo")]
    let state = AgentTuiWindowView.AgentTuiDisplayState(store: store)
    #expect(state.externalAgents.map(\.agentId) == ["alpha", "bravo", "charlie"])
  }

  @Test("Sorts external agents alphabetically by name")
  func sortsByName() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSession = makeSessionDetail(agents: [
      makeAgent(id: "z", name: "Zeta"),
      makeAgent(id: "a", name: "Alpha"),
      makeAgent(id: "m", name: "Mu"),
    ])
    let state = AgentTuiWindowView.AgentTuiDisplayState(store: store)
    #expect(state.externalAgents.map(\.name) == ["Alpha", "Mu", "Zeta"])
  }

  private func makeAgent(id: String, name: String) -> AgentRegistration {
    AgentRegistration(
      agentId: id,
      name: name,
      runtime: "claude",
      role: .worker,
      capabilities: [],
      joinedAt: "2026-04-22T09:00:00Z",
      updatedAt: "2026-04-22T09:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "claude",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 1,
        hookPoints: []
      ),
      persona: nil
    )
  }

  private func makeTuiSnapshot(tuiID: String, agentID: String) -> AgentTuiSnapshot {
    AgentTuiSnapshot(
      tuiId: tuiID,
      sessionId: "sess-fixture",
      agentId: agentID,
      runtime: "codex",
      status: .running,
      argv: ["codex"],
      projectDir: "/tmp/fixture",
      size: AgentTuiSize(rows: 24, cols: 80),
      screen: AgentTuiScreenSnapshot(rows: 24, cols: 80, cursorRow: 1, cursorCol: 1, text: ""),
      transcriptPath: "/tmp/\(tuiID).log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: "2026-04-22T09:00:00Z",
      updatedAt: "2026-04-22T09:00:00Z"
    )
  }

  private func makeSessionDetail(agents: [AgentRegistration]) -> SessionDetail {
    SessionDetail(
      session: PreviewFixtures.detail.session,
      agents: agents,
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
  }
}
