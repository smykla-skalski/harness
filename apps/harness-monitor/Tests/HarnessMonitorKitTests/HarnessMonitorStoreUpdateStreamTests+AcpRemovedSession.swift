import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("ACP snapshots for locally removed sessions are dropped without state changes")
  func acpSnapshotForLocallyRemovedSessionIsDropped() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.locallyRemovedSessionIDs.insert("removed-session")

    let outcome = store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-removed",
        sessionID: "removed-session",
        agentID: "worker",
        displayName: "Worker",
        pendingBatches: []
      )
    )

    #expect(outcome == .droppedSessionMismatch)
    #expect(store.selectedAcpAgents.isEmpty)
  }
}
