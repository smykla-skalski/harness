import Testing

@testable import HarnessMonitorKit

@Suite("Dashboard terminal agent management")
@MainActor
struct DashboardTerminalAgentManagementTests {
  @Test("Dashboard manages the complete terminal lifecycle through durable identity")
  func dashboardTerminalLifecycleEndToEnd() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let session = PreviewFixtures.summary
    let started = try #require(
      await store.startDashboardTerminalAgent(
        sessionID: session.sessionId,
        request: AgentTuiStartRequest(
          runtime: AgentTuiRuntime.copilot.rawValue,
          name: "Dashboard terminal",
          prompt: "Wait for terminal input",
          projectDir: session.checkoutRoot,
          rows: 32,
          cols: 120
        )
      ).snapshot
    )

    #expect(started.sessionId == session.sessionId)
    #expect(started.projectDir == session.checkoutRoot)
    client.detail = detailAddingTerminalMembership(
      client.detail,
      snapshot: started,
      name: "Dashboard terminal"
    )
    let loaded = await store.dashboardTerminalAgentDetail(
      managedAgentID: started.managedAgentID,
      sessionID: session.sessionId,
      sessionAgentID: started.sessionAgentID
    )
    #expect(loaded.snapshot == started)
    #expect(loaded.isMember == true)
    #expect(loaded.continuity.title == "Attached")

    let withInput = try #require(
      await store.sendDashboardTerminalInputSequence(
        agentID: started.managedAgentID,
        inputs: [.text("status"), .key(.enter)]
      )
    )
    #expect(withInput.screen.text.contains("status"))
    #expect(
      client.recordedCalls().contains { call in
        guard case .sendAgentTuiInput(_, let request) = call else { return false }
        return request.replayedInputs == [.text("status"), .key(.enter)]
      }
    )

    let resized = try #require(
      await store.resizeDashboardTerminalAgent(
        agentID: started.managedAgentID,
        rows: 40,
        cols: 132
      )
    )
    #expect(resized.size == AgentTuiSize(rows: 40, cols: 132))

    store.selectedSessionID = nil
    store.selectedSession = nil
    let signaled = await store.sendDashboardTerminalSignal(
      sessionID: session.sessionId,
      sessionAgentID: started.sessionAgentID,
      command: "inject_context",
      message: "Continue with the release checks",
      actionHint: "Report the final result"
    )
    #expect(signaled)
    expectSignalRecorded(
      client,
      sessionID: session.sessionId,
      agentID: started.sessionAgentID
    )

    let stopped = try #require(
      await store.stopDashboardTerminalAgent(agentID: started.managedAgentID)
    )
    #expect(stopped.status == .stopped)

    let removed = await store.removeDashboardTerminalMembership(
      sessionID: session.sessionId,
      sessionAgentID: started.sessionAgentID
    )
    #expect(removed)
    expectRemovalRecorded(
      client,
      sessionID: session.sessionId,
      agentID: started.sessionAgentID
    )
    let removedDetail = await store.dashboardTerminalAgentDetail(
      managedAgentID: started.managedAgentID,
      sessionID: session.sessionId,
      sessionAgentID: started.sessionAgentID
    )
    #expect(removedDetail.snapshot?.tuiId == started.managedAgentID)
    #expect(removedDetail.isMember == false)
  }

  @Test("Dashboard start failure leaves no phantom terminal agent")
  func dashboardTerminalStartFailureLeavesNoPhantomAgent() async {
    let client = RecordingHarnessClient()
    client.configureAgentTuiStartError(
      HarnessMonitorAPIError.semanticServer(
        code: 400,
        semanticCode: "WORKFLOW_IO",
        message: "Terminal bridge timed out"
      )
    )
    let store = await makeBootstrappedStore(client: client)
    let session = PreviewFixtures.summary

    let outcome = await store.startDashboardTerminalAgent(
      sessionID: session.sessionId,
      request: AgentTuiStartRequest(
        runtime: AgentTuiRuntime.copilot.rawValue,
        projectDir: session.checkoutRoot
      )
    )

    #expect(outcome.snapshot == nil)
    guard case .unknown = outcome else {
      Issue.record("Expected an unknown start outcome")
      return
    }
    #expect(client.configuredAgentTuis(for: session.sessionId).isEmpty)
    #expect(store.currentFailureFeedbackMessage?.contains("timed out") == true)
  }

  @Test("Definitive start rejection remains retryable")
  func dashboardTerminalStartRejectionIsDefinitive() async {
    let client = RecordingHarnessClient()
    client.configureAgentTuiStartError(
      HarnessMonitorAPIError.semanticServer(
        code: 400,
        semanticCode: "KSRCLI093",
        message: "Project directory is invalid"
      )
    )
    let store = await makeBootstrappedStore(client: client)

    let outcome = await store.startDashboardTerminalAgent(
      sessionID: PreviewFixtures.summary.sessionId,
      request: AgentTuiStartRequest(runtime: AgentTuiRuntime.codex.rawValue)
    )

    guard case .rejected(let message) = outcome else {
      Issue.record("Expected a rejected start outcome")
      return
    }
    #expect(message.contains("invalid"))
  }

  @Test("Unknown start outcome is reconciled into the Dashboard agent list")
  func dashboardTerminalUnknownStartOutcomeIsReconciled() async {
    let client = RecordingHarnessClient()
    client.configureAgentTuiStartErrorAfterRecord(
      HarnessMonitorAPIError.server(code: 504, message: "Terminal response timed out")
    )
    let store = await makeBootstrappedStore(client: client)
    let session = PreviewFixtures.summary

    let outcome = await store.startDashboardTerminalAgent(
      sessionID: session.sessionId,
      request: AgentTuiStartRequest(
        runtime: AgentTuiRuntime.codex.rawValue,
        projectDir: session.checkoutRoot
      )
    )
    guard case .unknown = outcome else {
      Issue.record("Expected an unknown start outcome")
      return
    }
    #expect(client.configuredAgentTuis(for: session.sessionId).count == 1)

    let refreshed = await store.refreshDashboardAgents(
      sessions: [session],
      cachedAgents: []
    )
    #expect(refreshed.agents.count == 1)
    #expect(refreshed.agents[0].runtimeKind == .terminal)
    #expect(refreshed.agents[0].lifecycle == .active)
  }

  private func detailAddingTerminalMembership(
    _ detail: SessionDetail,
    snapshot: AgentTuiSnapshot,
    name: String
  ) -> SessionDetail {
    let registration = AgentRegistration(
      agentId: snapshot.sessionAgentID,
      name: name,
      runtime: snapshot.runtime,
      role: .worker,
      capabilities: [],
      joinedAt: snapshot.createdAt,
      updatedAt: snapshot.updatedAt,
      status: .active,
      agentSessionId: "recording-terminal-\(snapshot.tuiId)",
      managedAgent: ManagedAgentRef(kind: .tui, id: snapshot.tuiId),
      lastActivityAt: snapshot.updatedAt,
      currentTaskId: nil,
      runtimeCapabilities: PreviewFixtures.agents[0].runtimeCapabilities,
      persona: nil
    )
    return SessionDetail(
      session: detail.session,
      agents: detail.agents + [registration],
      tasks: detail.tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )
  }

  private func expectSignalRecorded(
    _ client: RecordingHarnessClient,
    sessionID: String,
    agentID: String
  ) {
    #expect(
      client.recordedCalls().contains(
        .sendSignal(
          sessionID: sessionID,
          agentID: agentID,
          command: "inject_context",
          actor: "harness-app"
        )
      )
    )
  }

  private func expectRemovalRecorded(
    _ client: RecordingHarnessClient,
    sessionID: String,
    agentID: String
  ) {
    #expect(
      client.recordedCalls().contains(
        .removeAgent(
          sessionID: sessionID,
          agentID: agentID,
          actor: "harness-dashboard"
        )
      )
    )
  }
}
