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

  @Test("ACP same-batch replay preserves surviving selections and defaults new requests")
  func acpSameBatchReplayPreservesSurvivingSelectionsAndDefaultsNewRequests() throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-permission"
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-permission",
        pendingBatches: []
      )
    )

    let first = AcpPermissionBatch(
      batchId: "batch-1",
      acpId: "acp-1",
      sessionId: "sess-acp-permission",
      requests: [
        AcpPermissionItem(
          requestId: "request-keep",
          sessionId: "sess-acp-permission",
          toolCall: .object(["kind": .string("write")]),
          options: [.string("allow"), .string("deny")]
        ),
        AcpPermissionItem(
          requestId: "request-drop",
          sessionId: "sess-acp-permission",
          toolCall: .object(["kind": .string("read")]),
          options: [.string("allow"), .string("deny")]
        ),
      ],
      createdAt: "2026-04-28T00:00:01Z"
    )
    let replay = AcpPermissionBatch(
      batchId: "batch-1",
      acpId: "acp-1",
      sessionId: "sess-acp-permission",
      requests: [
        AcpPermissionItem(
          requestId: "request-keep",
          sessionId: "sess-acp-permission",
          toolCall: .object(["kind": .string("write")]),
          options: [.string("allow"), .string("deny")]
        ),
        AcpPermissionItem(
          requestId: "request-new",
          sessionId: "sess-acp-permission",
          toolCall: .object(["kind": .string("terminal.create")]),
          options: [.string("allow"), .string("deny")]
        ),
      ],
      createdAt: "2026-04-28T00:00:02Z"
    )

    store.applyAcpPermissionBatch(first)
    let decisionID = store.acpPermissionDecisionID(for: first.batchId)
    store.setAcpPermissionRequestSelection(
      decisionID: decisionID,
      requestID: "request-keep",
      isSelected: false
    )

    store.applyAcpPermissionBatch(replay)

    let state = try #require(store.acpPermissionResolutionState(for: decisionID))
    #expect(state.isSelected(requestID: "request-keep") == false)
    #expect(state.isSelected(requestID: "request-new"))
    #expect(!state.selectedRequestIDs.contains("request-drop"))
  }
}
