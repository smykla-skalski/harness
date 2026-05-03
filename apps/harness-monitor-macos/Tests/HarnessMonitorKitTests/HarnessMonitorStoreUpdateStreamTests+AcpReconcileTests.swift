import Foundation
import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test(
    "ACP reconcile replaces stale selected agents, clears stale batches, and restores canonical ordering"
  )
  func acpReconcileReplacesStaleSelectedAgentsAndBatches() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-reconcile"
    let staleBatch = makeAcpPermissionBatch(
      batchID: "batch-stale",
      acpID: "acp-stale",
      sessionID: "sess-acp-reconcile",
      createdAt: "2026-04-28T00:00:01Z"
    )
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-stale",
        sessionID: "sess-acp-reconcile",
        pendingBatches: [staleBatch]
      )
    )
    store.applyAcpPermissionBatch(staleBatch)

    store.replaceAcpAgents(
      AcpAgentsReconciledPayload(
        sessionId: "sess-acp-reconcile",
        agents: [
          makeAcpSnapshot(
            acpID: "zeta-agent",
            sessionID: "sess-acp-reconcile",
            displayName: "Zeta Agent",
            pendingBatches: []
          ),
          makeAcpSnapshot(
            acpID: "alpha-agent",
            sessionID: "sess-acp-reconcile",
            displayName: "Alpha Agent",
            pendingBatches: []
          ),
        ]
      )
    )

    #expect(store.selectedAcpAgents.map(\.acpId) == ["alpha-agent", "zeta-agent"])
    #expect(store.pendingAcpPermissionBatches.isEmpty)
  }

  @Test("ACP reconcile drops inspect snapshots whose runtime identity no longer matches")
  func acpReconcileDropsInspectSnapshotsWithSwappedRuntimeIdentity() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-reconcile"
    store.selectedAcpInspectState = AcpInspectSample(
      sessionID: "sess-acp-reconcile",
      sampledAt: Date(timeIntervalSince1970: 1),
      agents: [
        makeAcpInspectSnapshot(
          acpID: "acp-copilot",
          sessionID: "sess-acp-reconcile",
          agentID: "copilot",
          displayName: "Copilot"
        ),
        makeAcpInspectSnapshot(
          acpID: "acp-worker",
          sessionID: "sess-acp-reconcile",
          agentID: "worker",
          displayName: "Worker"
        ),
      ]
    )

    store.replaceAcpAgents(
      AcpAgentsReconciledPayload(
        sessionId: "sess-acp-reconcile",
        agents: [
          makeAcpSnapshot(
            acpID: "acp-copilot",
            sessionID: "sess-acp-reconcile",
            agentID: "worker",
            displayName: "Worker",
            pendingBatches: []
          ),
          makeAcpSnapshot(
            acpID: "acp-worker",
            sessionID: "sess-acp-reconcile",
            agentID: "copilot",
            displayName: "Copilot",
            pendingBatches: []
          ),
        ]
      )
    )

    #expect(store.selectedAcpInspectAgents.isEmpty)
    #expect(store.acpRuntimeState(for: "worker")?.inspect == nil)
    #expect(store.acpRuntimeState(for: "copilot")?.inspect == nil)
  }

  @Test("ACP reconcile keeps snapshot batch authoritative over stale standalone cache")
  func acpReconcilePrefersSnapshotBatchOverStandaloneCache() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-reconcile"

    let stale = makeAcpPermissionBatch(
      batchID: "batch-1",
      acpID: "acp-1",
      sessionID: "sess-acp-reconcile",
      createdAt: "2026-04-28T00:00:01Z"
    )
    store.applyAcpPermissionBatch(stale)

    let fresh = AcpPermissionBatch(
      batchId: "batch-1",
      acpId: "acp-1",
      sessionId: "sess-acp-reconcile",
      requests: [
        AcpPermissionItem(
          requestId: "request-fresh",
          sessionId: "sess-acp-reconcile",
          toolCall: .object(["kind": .string("write")]),
          options: [.string("allow")]
        )
      ],
      createdAt: "2026-04-28T00:00:02Z"
    )

    store.replaceAcpAgents(
      AcpAgentsReconciledPayload(
        sessionId: "sess-acp-reconcile",
        agents: [
          makeAcpSnapshot(
            acpID: "acp-1",
            sessionID: "sess-acp-reconcile",
            pendingBatches: [fresh]
          )
        ]
      )
    )

    #expect(store.standaloneAcpPermissionBatches.isEmpty)
    let requests =
      store.selectedAcpAgents.first?.pendingPermissionBatches.first?.requests.map(\.requestId)
    #expect(requests == ["request-fresh"])
  }
}
