import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("ACP permission batch waits for snapshot and remains presented")
  func acpPermissionBatchWaitsForSnapshotAndRemainsPresented() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-permission"
    let batch = makeAcpPermissionBatch(
      batchID: "batch-1",
      acpID: "acp-1",
      sessionID: "sess-acp-permission",
      createdAt: "2026-04-28T00:00:01Z"
    )

    store.applyAcpPermissionBatch(batch)

    #expect(store.pendingAcpPermissionBatches.map(\.batchId) == ["batch-1"])
    #expect(store.presentingAcpPermissionBatch?.batchId == "batch-1")

    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-permission",
        pendingBatches: []
      )
    )

    #expect(store.standaloneAcpPermissionBatches.isEmpty)
    #expect(store.selectedAcpAgents.first?.pendingPermissionBatches.map(\.batchId) == ["batch-1"])
    #expect(store.presentingAcpPermissionBatch?.batchId == "batch-1")
  }

  @Test("ACP permission batches coalesce and advance after removal")
  func acpPermissionBatchesCoalesceAndAdvanceAfterRemoval() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-permission"
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-permission",
        pendingBatches: []
      )
    )
    let newer = makeAcpPermissionBatch(
      batchID: "batch-2",
      acpID: "acp-1",
      sessionID: "sess-acp-permission",
      createdAt: "2026-04-28T00:00:02Z"
    )
    let older = makeAcpPermissionBatch(
      batchID: "batch-1",
      acpID: "acp-1",
      sessionID: "sess-acp-permission",
      createdAt: "2026-04-28T00:00:01Z"
    )

    store.applyAcpPermissionBatch(newer)
    store.applyAcpPermissionBatch(older)

    #expect(store.pendingAcpPermissionBatches.map(\.batchId) == ["batch-1", "batch-2"])
    #expect(store.presentingAcpPermissionBatch?.batchId == "batch-1")

    store.removeAcpPermissionBatch(older)

    #expect(store.pendingAcpPermissionBatches.map(\.batchId) == ["batch-2"])
    #expect(store.presentingAcpPermissionBatch?.batchId == "batch-2")
  }

  @Test("ACP permission batch apply updates last-signal freshness")
  func acpPermissionBatchApplyUpdatesLastSignalFreshness() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let sessionID = "sess-acp-freshness"
    store.selectedSessionID = sessionID
    let batch = makeAcpPermissionBatch(
      batchID: "batch-1",
      acpID: "acp-1",
      sessionID: sessionID,
      createdAt: "2026-04-28T00:00:01Z"
    )

    #expect(store.acpPermissionLastSignalAt(sessionID: sessionID) == nil)
    store.applyAcpPermissionBatch(batch)
    #expect(store.acpPermissionLastSignalAt(sessionID: sessionID) != nil)
  }

  @Test("ACP permission batch with same id refreshes presented request set")
  func acpPermissionBatchWithSameIDRefreshesPresentedRequestSet() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-permission"
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-permission",
        pendingBatches: []
      )
    )
    let first = makeAcpPermissionBatch(
      batchID: "batch-1",
      acpID: "acp-1",
      sessionID: "sess-acp-permission",
      createdAt: "2026-04-28T00:00:01Z"
    )
    let replacement = AcpPermissionBatch(
      batchId: "batch-1",
      acpId: "acp-1",
      sessionId: "sess-acp-permission",
      requests: first.requests + [
        AcpPermissionItem(
          requestId: "request-extra",
          sessionId: "sess-acp-permission",
          toolCall: .object(["kind": .string("terminal.create")]),
          options: []
        )
      ],
      createdAt: "2026-04-28T00:00:01Z"
    )

    store.applyAcpPermissionBatch(first)
    store.applyAcpPermissionBatch(replacement)

    #expect(store.pendingAcpPermissionBatches.count == 1)
    let presentedRequestIDs = store.presentingAcpPermissionBatch?.requests.map(\.requestId)
    #expect(presentedRequestIDs?.contains("request-extra") == true)
  }
}
