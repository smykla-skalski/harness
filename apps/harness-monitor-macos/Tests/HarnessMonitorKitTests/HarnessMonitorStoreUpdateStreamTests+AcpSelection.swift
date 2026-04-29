import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("ACP resolving batch stays presented when newer batch arrives")
  func acpResolvingBatchStaysPresentedWhenNewerBatchArrives() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-permission"
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-permission",
        pendingBatches: []
      )
    )

    let current = makeAcpPermissionBatch(
      batchID: "batch-1",
      acpID: "acp-1",
      sessionID: "sess-acp-permission",
      createdAt: "2026-04-28T00:00:01Z"
    )
    let newer = makeAcpPermissionBatch(
      batchID: "batch-2",
      acpID: "acp-1",
      sessionID: "sess-acp-permission",
      createdAt: "2026-04-28T00:00:02Z"
    )

    store.applyAcpPermissionBatch(current)
    store.resolvingAcpPermissionBatchID = current.batchId
    store.applyAcpPermissionBatch(newer)

    #expect(
      store.pendingAcpPermissionBatches.map(\.batchId) == ["batch-1", "batch-2"]
    )
    #expect(store.presentingAcpPermissionBatch?.batchId == "batch-1")
  }
}
