import Foundation
import Testing

@testable import HarnessMonitorKit

struct AcpDecisionAttentionTests {
  @Test("ACP decision attention counts pending requests for one agent")
  @MainActor
  func countsPendingRequestsForAgent() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-attention"
    store.applyAcpAgent(
      makeWorkerSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-attention",
        pendingBatches: [
          makeAcpPermissionBatch(
            batchID: "batch-1",
            acpID: "acp-1",
            sessionID: "sess-acp-attention",
            createdAt: "2026-04-28T00:00:01Z"
          ),
          makeAcpPermissionBatch(
            batchID: "batch-2",
            acpID: "acp-1",
            sessionID: "sess-acp-attention",
            createdAt: "2026-04-28T00:00:02Z"
          ),
        ]
      )
    )

    let attention = store.acpDecisionAttention(for: "worker-codex")

    #expect(attention?.count == 2)
    #expect(attention?.oldestBatchID == "batch-1")
  }

  @Test("oldest decision selection picks oldest open row for agent")
  @MainActor
  func selectsOldestDecisionForAgent() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let older = Decision(
      id: "decision-old",
      severity: .warn,
      ruleID: "stuck-agent",
      sessionID: "sess-acp-attention",
      agentID: "worker-codex",
      taskID: nil,
      summary: "Older",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    older.createdAt = Date(timeIntervalSince1970: 10)

    let newer = Decision(
      id: "decision-new",
      severity: .warn,
      ruleID: "stuck-agent",
      sessionID: "sess-acp-attention",
      agentID: "worker-codex",
      taskID: nil,
      summary: "Newer",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    newer.createdAt = Date(timeIntervalSince1970: 20)

    store.supervisorOpenDecisions = [newer, older]

    let selectedID = store.selectOldestDecision(for: "worker-codex")

    #expect(selectedID == "decision-old")
    #expect(store.supervisorSelectedDecisionID == "decision-old")
  }

  private func makeWorkerSnapshot(
    acpID: String,
    sessionID: String,
    pendingBatches: [AcpPermissionBatch]
  ) -> AcpAgentSnapshot {
    AcpAgentSnapshot(
      acpId: acpID,
      sessionId: sessionID,
      agentId: "worker-codex",
      displayName: "Worker Codex",
      status: .active,
      pid: 12_345,
      pgid: 12_345,
      projectDir: "/tmp/project",
      pendingPermissions: pendingBatches.reduce(0) { $0 + $1.requests.count },
      permissionQueueDepth: pendingBatches.count,
      pendingPermissionBatches: pendingBatches,
      terminalCount: 0,
      createdAt: "2026-04-28T00:00:00Z",
      updatedAt: "2026-04-28T00:00:00Z"
    )
  }
}
