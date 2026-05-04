import Foundation
import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("ACP agent updates replace the same agent row when the runtime restarts")
  func acpRuntimeLookupReplacesRestartedAgentSnapshot() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-restart"
    store.selectedAcpInspectState = AcpInspectSample(
      sessionID: "sess-acp-restart",
      sampledAt: Date(timeIntervalSince1970: 5),
      agents: [
        makeAcpInspectSnapshot(
          acpID: "acp-1",
          sessionID: "sess-acp-restart",
          agentID: "worker",
          displayName: "Worker Inspect"
        )
      ]
    )
    #expect(store.acpRuntimeState(for: "worker")?.inspect?.displayName == "Worker Inspect")
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-restart",
        agentID: "worker",
        displayName: "Worker One",
        pendingBatches: []
      )
    )
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-2",
        sessionID: "sess-acp-restart",
        agentID: "worker",
        displayName: "Worker Two",
        pendingBatches: []
      )
    )

    #expect(store.selectedAcpAgents.count == 1)
    #expect(store.selectedAcpAgents.map(\.id) == ["worker"])
    #expect(store.acpAgentSnapshot(for: "worker")?.acpId == "acp-2")
    #expect(store.acpRuntimeState(for: "worker")?.snapshot?.displayName == "Worker Two")
    #expect(store.acpRuntimeState(for: "worker")?.inspect == nil)
    #expect(store.acpRuntimeInspectStatus(for: "worker")?.phase == .waiting)
  }

  @Test("ACP agent updates preserve inspect for the same runtime identity")
  func acpAgentUpdatePreservesInspectForSameRuntimeIdentity() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-preserve"
    store.selectedAcpInspectState = AcpInspectSample(
      sessionID: "sess-acp-preserve",
      sampledAt: Date(timeIntervalSince1970: 10),
      agents: [
        makeAcpInspectSnapshot(
          acpID: "acp-1",
          sessionID: "sess-acp-preserve",
          agentID: "worker",
          displayName: "Worker Inspect"
        )
      ]
    )

    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-preserve",
        agentID: "worker",
        displayName: "Worker Snapshot",
        pendingBatches: []
      )
    )

    #expect(store.acpRuntimeState(for: "worker")?.inspect?.displayName == "Worker Inspect")
    #expect(store.acpRuntimeInspectStatus(for: "worker")?.phase == .ready)
  }

  @Test("ACP runtime restart purges stale standalone permission state for the replaced runtime")
  func acpRuntimeRestartPurgesStaleStandalonePermissionState() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-restart"

    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-restart",
        agentID: "worker",
        displayName: "Worker One",
        pendingBatches: []
      )
    )

    let staleBatch = makeAcpPermissionBatch(
      batchID: "batch-stale",
      acpID: "acp-1",
      sessionID: "sess-acp-restart",
      createdAt: "2026-04-28T00:00:01Z"
    )
    let staleDecisionID = store.acpPermissionDecisionID(for: staleBatch.batchId)
    store.standaloneAcpPermissionBatches = [staleBatch]
    store.reconcileAcpPermissionDecisions()
    #expect(store.acpPermissionDecisionPayload(for: staleDecisionID)?.rawBatch.batchId == "batch-stale")

    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-2",
        sessionID: "sess-acp-restart",
        agentID: "worker",
        displayName: "Worker Two",
        pendingBatches: []
      )
    )

    #expect(store.selectedAcpAgents.count == 1)
    #expect(store.acpAgentSnapshot(for: "worker")?.acpId == "acp-2")
    #expect(store.standaloneAcpPermissionBatches.isEmpty)
    #expect(store.pendingAcpPermissionBatches.isEmpty)
    #expect(store.acpPermissionDecisionPayload(for: staleDecisionID) == nil)
    #expect(store.acpPermissionResolutionState(for: staleDecisionID) == nil)
  }

  @Test("ACP runtime clock only runs while the selected inspect sample has an active deadline")
  func acpRuntimeClockStartsAndStopsWithSelectedInspectState() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let now = Date.now

    store.selectedAcpInspectState = AcpInspectSample(
      sessionID: "sess-acp-clock",
      sampledAt: now,
      agents: [
        makeAcpInspectSnapshot(
          acpID: "acp-1",
          sessionID: "sess-acp-clock",
          agentID: "worker",
          displayName: "Worker",
          promptDeadlineRemainingMs: 5_000
        )
      ]
    )
    #expect(store.acpRuntimeClockTask != nil)

    store.selectedAcpInspectState = AcpInspectSample(
      sessionID: "sess-acp-clock",
      sampledAt: now.addingTimeInterval(-10),
      agents: [
        makeAcpInspectSnapshot(
          acpID: "acp-1",
          sessionID: "sess-acp-clock",
          agentID: "worker",
          displayName: "Worker",
          promptDeadlineRemainingMs: 1_000
        )
      ]
    )
    #expect(store.acpRuntimeClockTask == nil)

    store.selectedAcpInspectState = nil
    #expect(store.acpRuntimeClockTask == nil)
  }

  @Test("ACP reconcile can hydrate inspect telemetry inline")
  func acpReconcileHydratesInlineInspectTelemetry() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-inline"

    store.replaceAcpAgents(
      AcpAgentsReconciledPayload(
        sessionId: "sess-acp-inline",
        agents: [
          makeAcpSnapshot(
            acpID: "acp-1",
            sessionID: "sess-acp-inline",
            agentID: "worker",
            displayName: "Worker Snapshot",
            pendingBatches: []
          )
        ],
        inspect: AcpAgentInspectResponse(
          agents: [
            makeAcpInspectSnapshot(
              acpID: "acp-1",
              sessionID: "sess-acp-inline",
              agentID: "worker",
              displayName: "Worker Inspect"
            )
          ]
        )
      ),
      sampledAt: Date(timeIntervalSince1970: 12)
    )

    #expect(store.selectedAcpInspectAgents.map(\.agentId) == ["worker"])
    #expect(store.acpRuntimeState(for: "worker")?.inspect?.displayName == "Worker Inspect")
    #expect(store.acpRuntimeInspectStatus(for: "worker")?.phase == .ready)
  }
}
