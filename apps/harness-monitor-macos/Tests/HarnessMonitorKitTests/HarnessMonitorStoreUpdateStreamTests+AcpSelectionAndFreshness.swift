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
