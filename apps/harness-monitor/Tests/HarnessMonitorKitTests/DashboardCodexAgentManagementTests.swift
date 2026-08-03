import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Dashboard Codex agent management")
@MainActor
struct DashboardCodexAgentManagementTests {
  @Test("Dashboard creates, steers, approves, observes transcript, and stops Codex")
  func dashboardCodexLifecycleEndToEnd() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let session = PreviewFixtures.summary
    let started = try #require(
      await store.startDashboardCodexAgent(
        sessionID: session.sessionId,
        request: CodexRunRequest(
          actor: nil,
          prompt: "Inspect the Dashboard agents route",
          mode: .workspaceWrite,
          name: "Dashboard Codex",
          model: "gpt-5.6-codex",
          effort: "high",
          allowCustomModel: true
        )
      )
    )

    #expect(started.managedAgentID == "codex-run-1")
    #expect(started.projectDir == session.checkoutRoot)
    #expect(
      client.recordedCalls().contains {
        if case .startCodexRun(
          sessionID: session.sessionId,
          prompt: "Inspect the Dashboard agents route",
          mode: .workspaceWrite,
          actor: "harness-dashboard",
          resumeThreadID: nil
        ) = $0 {
          return true
        }
        return false
      }
    )

    let startedDetail = await detail(store: store, run: started, session: session)
    #expect(startedDetail.run?.managedAgentID == started.managedAgentID)
    #expect(startedDetail.transcript.map(\.summary) == [started.prompt])
    #expect(startedDetail.continuity.title == "Attached")

    let steered = try #require(
      await store.steerDashboardCodexAgent(
        agentID: started.managedAgentID,
        prompt: "Now inspect the reconnect path"
      )
    )
    #expect(steered.latestSummary == "Accepted new context.")

    let approval = client.codexApprovalFixture(approvalID: "dashboard-approval")
    let waiting = client.codexRunFixture(
      runID: started.runId,
      sessionID: session.sessionId,
      mode: started.mode,
      status: .waitingApproval,
      prompt: started.prompt,
      pendingApprovals: [approval],
      displayName: started.displayName
    )
    client.configureCodexRuns([waiting], for: session.sessionId)

    let pendingDetail = await detail(store: store, run: waiting, session: session)
    #expect(pendingDetail.pendingApprovals.map(\.approvalId) == [approval.approvalId])
    let resolved = try #require(
      await store.resolveDashboardCodexApproval(
        agentID: waiting.managedAgentID,
        approvalID: approval.approvalId,
        decision: .accept
      )
    )
    #expect(resolved.pendingApprovals.isEmpty)

    let stopped = try #require(
      await store.stopDashboardCodexAgent(agentID: waiting.managedAgentID)
    )
    #expect(stopped.status == .cancelled)
    let stoppedDetail = await detail(store: store, run: stopped, session: session)
    #expect(stoppedDetail.continuity.title == "Stopped")
  }

  @Test("Dashboard transcript keeps only the selected managed Codex identity")
  func dashboardCodexTranscriptIsIdentityScoped() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let session = PreviewFixtures.summary
    let selected = client.codexRunFixture(
      runID: "codex-selected",
      sessionID: session.sessionId,
      prompt: "Selected prompt"
    )
    let neighbor = client.codexRunFixture(
      runID: "codex-neighbor",
      sessionID: session.sessionId,
      prompt: "Neighbor prompt"
    )
    client.configureCodexRuns([selected, neighbor], for: session.sessionId)
    client.configureCodexTranscriptResponse(
      CodexTranscriptResponse(
        entries: [selected, neighbor].flatMap(RecordingHarnessClient.codexTranscriptEntries)
      ),
      for: session.sessionId
    )

    let result = await detail(store: store, run: selected, session: session)

    #expect(result.transcript.map(\.summary) == ["Selected prompt"])
    #expect(result.inspect?.runId == selected.runId)
  }

  private func detail(
    store: HarnessMonitorStore,
    run: CodexRunSnapshot,
    session: SessionSummary
  ) async -> DashboardCodexAgentDetail {
    await store.dashboardCodexAgentDetail(
      managedAgentID: run.managedAgentID,
      sessionID: session.sessionId,
      sessionAgentID: run.sessionAgentID
    )
  }
}
