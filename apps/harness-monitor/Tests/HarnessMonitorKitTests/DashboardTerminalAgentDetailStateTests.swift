import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard terminal agent detail state")
@MainActor
struct DashboardTerminalAgentDetailStateTests {
  @Test("Late action completion cannot overwrite a new terminal selection")
  func staleActionCompletionIsIgnored() throws {
    let state = DashboardTerminalAgentDetailState(agentID: "terminal-a")
    let firstToken = try #require(state.beginAction("Stopping terminal agent"))
    let loadGeneration = try #require(state.beginLoad(agentID: "terminal-b"))
    state.finishLoad(
      DashboardTerminalAgentDetail(snapshot: nil, issues: []),
      generation: loadGeneration
    )
    let secondToken = try #require(state.beginAction("Stopping terminal agent"))

    state.finishAction(firstToken, snapshot: snapshot(id: "terminal-a"))
    #expect(state.activeAction == "Stopping terminal agent")
    #expect(state.detail?.snapshot == nil)

    state.finishAction(secondToken, snapshot: snapshot(id: "terminal-b"))
    #expect(state.activeAction == nil)
    #expect(state.detail?.snapshot?.tuiId == "terminal-b")
  }

  @Test("Late input completion preserves the new terminal draft")
  func staleInputCompletionPreservesDraft() throws {
    let state = DashboardTerminalAgentDetailState(agentID: "terminal-a")
    let firstToken = try #require(state.beginAction("Sending terminal input"))
    let loadGeneration = try #require(state.beginLoad(agentID: "terminal-b"))
    state.finishLoad(
      DashboardTerminalAgentDetail(snapshot: nil, issues: []),
      generation: loadGeneration
    )
    state.input = "Draft for B"

    state.finishInput(firstToken, snapshot: snapshot(id: "terminal-a"))

    #expect(state.input == "Draft for B")
    #expect(state.detail?.snapshot == nil)
  }

  @Test("Signal draft and completion stay scoped to one terminal identity")
  func signalDraftIsIdentityScoped() throws {
    let state = DashboardTerminalSignalState()
    state.prepare(agentID: "terminal-a")
    state.message = "Draft for A"
    let token = try #require(state.beginSend(agentID: "terminal-a"))

    state.prepare(agentID: "terminal-b")
    state.message = "Draft for B"
    state.finishSend(token, succeeded: true)

    #expect(state.represents(agentID: "terminal-b"))
    #expect(state.message == "Draft for B")
    #expect(!state.isSending)
  }

  @Test("Terminal actions preserve reconciled membership")
  func terminalActionPreservesMembership() throws {
    let state = DashboardTerminalAgentDetailState(
      detail: DashboardTerminalAgentDetail(
        snapshot: snapshot(id: "terminal-a"),
        isMember: false,
        issues: []
      ),
      agentID: "terminal-a"
    )
    let token = try #require(state.beginAction("Stopping terminal agent"))

    state.finishAction(token, snapshot: snapshot(id: "terminal-a"))

    #expect(state.detail?.isMember == false)
  }

  @Test("Output polls preserve reconciled membership")
  func outputPollPreservesMembership() throws {
    let state = DashboardTerminalAgentDetailState(
      detail: DashboardTerminalAgentDetail(
        snapshot: snapshot(id: "terminal-a"),
        isMember: false,
        issues: []
      ),
      agentID: "terminal-a"
    )
    let generation = try #require(state.beginLoad(agentID: "terminal-a"))

    state.finishLoad(
      DashboardTerminalAgentDetail(snapshot: snapshot(id: "terminal-a"), issues: []),
      generation: generation
    )

    #expect(state.detail?.isMember == false)
  }

  @Test("Output polls preserve membership reconciliation warnings")
  func outputPollPreservesMembershipWarning() throws {
    let warning = "Membership unavailable: bridge disconnected"
    let state = DashboardTerminalAgentDetailState(
      detail: DashboardTerminalAgentDetail(
        snapshot: snapshot(id: "terminal-a"),
        issues: [warning]
      ),
      agentID: "terminal-a"
    )
    let generation = try #require(state.beginLoad(agentID: "terminal-a"))

    state.finishLoad(
      DashboardTerminalAgentDetail(snapshot: snapshot(id: "terminal-a"), issues: []),
      generation: generation
    )

    #expect(state.detail?.issues == [warning])
  }

  private func snapshot(id: String) -> AgentTuiSnapshot {
    AgentTuiPreviewSupport.snapshot(
      tuiID: id,
      spec: AgentTuiSnapshotSpec(
        agentID: "session-\(id)",
        runtime: .codex,
        status: .stopped,
        size: AgentTuiSize(rows: 32, cols: 120),
        text: "Stopped"
      )
    )
  }
}
