import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Dashboard store decision resolution")
@MainActor
struct DashboardStoreDecisionResolutionTests {
  @Test("Supervisor decision resolves to its session's workspace bucket")
  func supervisorDecisionResolvesWorkspace() async {
    let store = await makeBootstrappedStore()
    let session = PreviewFixtures.summary
    _ = store.sessionIndex.applySessionSummary(session)
    store.supervisorOpenDecisions = [
      Decision(
        id: "stuck-agent:1",
        severity: .critical,
        ruleID: "stuck-agent",
        sessionID: session.sessionId,
        agentID: nil,
        taskID: nil,
        summary: "Agent has stalled",
        contextJSON: "{}",
        suggestedActionsJSON: "[]"
      )
    ]

    let resolution = store.dashboardDecisionResolution(agents: [])
    let workspace = HarnessMonitorStore.dashboardAgentWorkspace(session)

    #expect(resolution.workspaceBuckets.count == 1)
    #expect(resolution.workspaceBuckets.first?.workspace.identity == workspace.identity)
    #expect(resolution.workspaceBuckets.first?.items.first?.id == "stuck-agent:1")
    #expect(resolution.itemsByAgent.isEmpty)
  }

  @Test("ACP permission attaches to its loaded managed agent")
  func acpDecisionAttachesToLoadedAgent() async {
    let store = await makeBootstrappedStore()
    let session = PreviewFixtures.summary
    _ = store.sessionIndex.applySessionSummary(session)
    let batch = makeBatch(sessionID: session.sessionId)
    store.supervisorOpenDecisions = [
      acpDecision(id: "acp-permission:batch-1", sessionID: session.sessionId, batch: batch)
    ]

    let workspace = HarnessMonitorStore.dashboardAgentWorkspace(session)
    let agent = DashboardAgentSummary(
      identity: DashboardAgentIdentity(
        workspace: workspace.identity,
        runtimeKind: .acp,
        managedAgentID: batch.acpId
      ),
      workspace: workspace,
      sessionID: session.sessionId,
      sessionAgentID: "worker-codex",
      displayName: "Worker",
      lifecycle: .waiting,
      summary: nil,
      projectDirectory: workspace.checkoutRoot,
      createdAt: "2026-08-02T07:00:00Z",
      updatedAt: "2026-08-02T08:00:00Z",
      source: .live
    )

    let resolution = store.dashboardDecisionResolution(agents: [agent])

    #expect(resolution.itemsByAgent[agent.identity]?.count == 1)
    #expect(resolution.itemsByAgent[agent.identity]?.first?.kind == .acpPermission)
    #expect(resolution.summaryByAgent[agent.identity]?.count == 1)
    #expect(resolution.workspaceBuckets.isEmpty)
  }

  @Test("Codex approval attaches by managed run identity instead of session agent identity")
  func codexApprovalAttachesToManagedRun() async {
    let store = await makeBootstrappedStore()
    let session = PreviewFixtures.summary
    _ = store.sessionIndex.applySessionSummary(session)
    store.supervisorOpenDecisions = [
      Decision(
        id: "codex-approval:\(session.sessionId):approval-1",
        severity: .needsUser,
        ruleID: "codex-approval",
        sessionID: session.sessionId,
        agentID: "codex-run-1",
        taskID: nil,
        summary: "Approve command",
        contextJSON: "{}",
        suggestedActionsJSON: "[]"
      )
    ]
    let workspace = HarnessMonitorStore.dashboardAgentWorkspace(session)
    let agent = DashboardAgentSummary(
      identity: DashboardAgentIdentity(
        workspace: workspace.identity,
        runtimeKind: .codex,
        managedAgentID: "codex-run-1"
      ),
      workspace: workspace,
      sessionID: session.sessionId,
      sessionAgentID: "session-agent-1",
      displayName: "Codex",
      lifecycle: .waiting,
      summary: nil,
      projectDirectory: workspace.checkoutRoot,
      createdAt: "2026-08-02T07:00:00Z",
      updatedAt: "2026-08-02T08:00:00Z",
      source: .live
    )

    let resolution = store.dashboardDecisionResolution(agents: [agent])

    #expect(resolution.itemsByAgent[agent.identity]?.count == 1)
    #expect(resolution.workspaceBuckets.isEmpty)
  }

  @Test("Supervisor decision with no encoded actions receives fallback dismiss")
  func supervisorDecisionReceivesFallbackDismiss() async {
    let store = await makeBootstrappedStore()
    let session = PreviewFixtures.summary
    _ = store.sessionIndex.applySessionSummary(session)
    store.supervisorOpenDecisions = [
      Decision(
        id: "observer-issue-escalation:\(session.sessionId)",
        severity: .warn,
        ruleID: "observer-issue-escalation",
        sessionID: session.sessionId,
        agentID: nil,
        taskID: nil,
        summary: "Observer reported repeated issues",
        contextJSON: "{}",
        suggestedActionsJSON: "[]"
      )
    ]

    let resolution = store.dashboardDecisionResolution(agents: [])
    let actions = resolution.workspaceBuckets.first?.items.first?.suggestedActions

    #expect(actions?.map(\.kind) == [.dismiss])
  }

  private func makeBatch(sessionID: String) -> AcpPermissionBatch {
    AcpPermissionBatch(
      batchId: "batch-1",
      acpId: "acp-1",
      sessionId: sessionID,
      requests: [
        AcpPermissionItem(
          requestId: "request-write",
          sessionId: sessionID,
          toolCall: .object([
            "kind": .string("fs.write_text_file"),
            "path": .string("Sources/App.swift"),
          ]),
          options: []
        )
      ],
      createdAt: "2026-04-28T00:00:01Z",
      expiresAt: nil
    )
  }

  private func acpDecision(
    id: String,
    sessionID: String,
    batch: AcpPermissionBatch
  ) -> Decision {
    let payload = AcpPermissionDecisionPayload(
      decisionID: id,
      summary: "Persisted row summary",
      agent: .init(
        agentID: "worker-codex",
        agentName: "Worker Codex",
        managedAgentID: batch.acpId
      ),
      rawBatch: batch,
      renderableBatch: .init(
        batch: batch,
        requests: [
          .init(
            id: batch.requests.first?.requestId ?? "request-stale",
            title: "Write file",
            detail: "Sources/App.swift",
            breadcrumb: "fs.write_text_file"
          )
        ]
      ),
      renderError: nil
    )
    return Decision(
      id: id,
      severity: .warn,
      ruleID: AcpPermissionDecisionPayload.ruleID,
      sessionID: sessionID,
      agentID: "worker-codex",
      taskID: nil,
      summary: "Persisted row summary",
      contextJSON: payload.encodeJSONString(),
      suggestedActionsJSON: payload.encodedSuggestedActionsJSON()
    )
  }
}
