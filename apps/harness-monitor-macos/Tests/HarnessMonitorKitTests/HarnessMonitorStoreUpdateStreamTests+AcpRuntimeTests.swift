import Foundation
import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("ACP runtime lookup refuses ambiguous selected snapshots")
  func acpRuntimeLookupRejectsDuplicateAgentIDs() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-ambiguous"
    store.selectedAcpInspectState = AcpInspectSample(
      sessionID: "sess-acp-ambiguous",
      sampledAt: Date(timeIntervalSince1970: 5),
      agents: [
        makeAcpInspectSnapshot(
          acpID: "acp-1",
          sessionID: "sess-acp-ambiguous",
          agentID: "worker",
          displayName: "Worker Inspect"
        )
      ]
    )
    #expect(store.acpRuntimeState(for: "worker")?.inspect?.displayName == "Worker Inspect")
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-ambiguous",
        agentID: "worker",
        displayName: "Worker One",
        pendingBatches: []
      )
    )
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-2",
        sessionID: "sess-acp-ambiguous",
        agentID: "worker",
        displayName: "Worker Two",
        pendingBatches: []
      )
    )

    #expect(store.acpAgentSnapshot(for: "worker") == nil)
    #expect(store.acpRuntimeState(for: "worker") == nil)
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
