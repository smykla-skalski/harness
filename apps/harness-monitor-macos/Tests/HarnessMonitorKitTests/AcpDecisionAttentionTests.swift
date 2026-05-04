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
    #expect(attention?.oldestDecisionID == "acp-permission:batch-1")
  }

  @Test("oldest decision selection picks deterministic ACP decision for oldest batch")
  @MainActor
  func selectsOldestDecisionForAgent() {
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

    let selectedID = store.selectOldestDecision(for: "worker-codex")

    #expect(selectedID == "acp-permission:batch-1")
    #expect(store.supervisorSelectedDecisionID == "acp-permission:batch-1")
  }

  @Test("ACP attention events route batches to the deterministic ACP decision")
  @MainActor
  func buildsAcpPermissionAttentionEvents() {
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
          )
        ]
      )
    )

    let events = store.acpPermissionAttentionEvents

    #expect(events.count == 1)
    #expect(events.first?.batchID == "batch-1")
    #expect(events.first?.decisionID == "acp-permission:batch-1")
    #expect(events.first?.agentID == "worker-codex")
    #expect(events.first?.agentName == "Worker Codex")
    #expect(events.first?.toastMessage == "Permission requested by Worker Codex. Workspace window.")
  }

  @Test("ACP attention cache refreshes when selected ACP agents are replaced directly")
  @MainActor
  func refreshesAttentionCacheWhenSelectedAgentsChange() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-attention"
    store.selectedAcpAgents = [
      makeWorkerSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-attention",
        pendingBatches: [
          makeAcpPermissionBatch(
            batchID: "batch-1",
            acpID: "acp-1",
            sessionID: "sess-acp-attention",
            createdAt: "2026-04-28T00:00:01Z"
          )
        ]
      )
    ]

    #expect(store.acpDecisionAttention(for: "worker-codex")?.oldestBatchID == "batch-1")
    #expect(store.acpPermissionAttentionEvents.map(\.batchID) == ["batch-1"])

    store.selectedAcpAgents = [
      makeWorkerSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-attention",
        pendingBatches: []
      )
    ]

    #expect(store.acpDecisionAttention(for: "worker-codex") == nil)
    #expect(store.acpPermissionAttentionEvents.isEmpty)
  }

  @Test("ACP attention events sort by oldest pending batch across agents")
  @MainActor
  func sortsAttentionEventsAcrossAgentsByDaemonOrdering() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-attention"
    store.selectedAcpAgents = [
      makeWorkerSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-attention",
        agentID: "worker-z",
        displayName: "Worker Z",
        pendingBatches: [
          makeAcpPermissionBatch(
            batchID: "batch-2",
            acpID: "acp-1",
            sessionID: "sess-acp-attention",
            createdAt: "2026-04-28T00:00:02Z"
          )
        ]
      ),
      makeWorkerSnapshot(
        acpID: "acp-2",
        sessionID: "sess-acp-attention",
        agentID: "worker-b",
        displayName: "Worker B",
        pendingBatches: [
          makeAcpPermissionBatch(
            batchID: "batch-9",
            acpID: "acp-2",
            sessionID: "sess-acp-attention",
            createdAt: "2026-04-28T00:00:01Z"
          )
        ]
      ),
      makeWorkerSnapshot(
        acpID: "acp-3",
        sessionID: "sess-acp-attention",
        agentID: "worker-a",
        displayName: "Worker A",
        pendingBatches: [
          makeAcpPermissionBatch(
            batchID: "batch-1",
            acpID: "acp-3",
            sessionID: "sess-acp-attention",
            createdAt: "2026-04-28T00:00:01Z"
          )
        ]
      ),
    ]

    #expect(store.acpPermissionAttentionEvents.map(\.batchID) == ["batch-1", "batch-9", "batch-2"])
    #expect(
      store.acpPermissionAttentionEvents.map(\.decisionID) == [
        "acp-permission:batch-1",
        "acp-permission:batch-9",
        "acp-permission:batch-2",
      ])
  }

  @Test("ACP attention uses batch ID to break same-timestamp ties within one agent")
  @MainActor
  func breaksSameTimestampTiesWithinOneAgent() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-attention"
    store.selectedAcpAgents = [
      makeWorkerSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-attention",
        pendingBatches: [
          makeAcpPermissionBatch(
            batchID: "batch-9",
            acpID: "acp-1",
            sessionID: "sess-acp-attention",
            createdAt: "2026-04-28T00:00:01Z"
          ),
          makeAcpPermissionBatch(
            batchID: "batch-1",
            acpID: "acp-1",
            sessionID: "sess-acp-attention",
            createdAt: "2026-04-28T00:00:01Z"
          ),
        ]
      )
    ]

    let attention = store.acpDecisionAttention(for: "worker-codex")

    #expect(attention?.count == 2)
    #expect(attention?.oldestBatchID == "batch-1")
    #expect(attention?.oldestDecisionID == "acp-permission:batch-1")
    #expect(store.acpPermissionAttentionEvents.map(\.batchID) == ["batch-1"])
    #expect(store.acpPermissionAttentionEvents.map(\.decisionID) == ["acp-permission:batch-1"])
  }

  @Test("ACP attention always routes pending batches to a matching ACP decision")
  @MainActor
  func routesPendingAttentionWithoutGenericSupervisorRows() {
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
          )
        ]
      )
    )

    #expect(
      store.acpDecisionAttention(for: "worker-codex")?.oldestDecisionID == "acp-permission:batch-1")
    #expect(store.acpPermissionAttentionEvents.first?.decisionID == "acp-permission:batch-1")
    #expect(store.selectOldestDecision(for: "worker-codex") == "acp-permission:batch-1")
  }

  private func makeWorkerSnapshot(
    acpID: String,
    sessionID: String,
    agentID: String = "worker-codex",
    displayName: String = "Worker Codex",
    pendingBatches: [AcpPermissionBatch]
  ) -> AcpAgentSnapshot {
    AcpAgentSnapshot(
      acpId: acpID,
      sessionId: sessionID,
      agentId: agentID,
      displayName: displayName,
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
