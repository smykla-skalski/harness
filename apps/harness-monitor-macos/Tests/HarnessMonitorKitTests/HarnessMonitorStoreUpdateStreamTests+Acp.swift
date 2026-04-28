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

  @Test("ACP reconcile replaces stale selected agents and batches")
  func acpReconcileReplacesStaleSelectedAgentsAndBatches() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-reconcile"
    let staleBatch = makeAcpPermissionBatch(
      batchID: "batch-stale",
      acpID: "acp-stale",
      sessionID: "sess-acp-reconcile",
      createdAt: "2026-04-28T00:00:01Z"
    )
    store.applyAcpAgent(makeAcpSnapshot(acpID: "acp-stale", sessionID: "sess-acp-reconcile", pendingBatches: [staleBatch]))
    store.applyAcpPermissionBatch(staleBatch)

    store.replaceAcpAgents(
      AcpAgentsReconciledPayload(
        sessionId: "sess-acp-reconcile",
        agents: [makeAcpSnapshot(acpID: "acp-fresh", sessionID: "sess-acp-reconcile", pendingBatches: [])]
      )
    )

    #expect(store.selectedAcpAgents.map(\.acpId) == ["acp-fresh"])
    #expect(store.pendingAcpPermissionBatches.isEmpty)
  }

  @Test("ACP event push appends selected session timeline")
  func acpEventPushAppendsSelectedSessionTimeline() async throws {
    let client = RecordingHarnessClient()
    let summary = makeSession(
      .init(
        sessionId: "sess-acp-events",
        context: "ACP timeline",
        status: .active,
        leaderId: "leader-acp",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-acp",
      workerName: "Worker ACP"
    )
    let initialTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-acp",
      summary: "Initial timeline"
    )
    client.configureSessions(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: initialTimeline]
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )

    await store.bootstrap()
    await store.selectSession(summary.sessionId)
    store.applySessionPushEvent(
      DaemonPushEvent(
        recordedAt: "2026-04-28T00:00:30Z",
        sessionId: summary.sessionId,
        kind: .acpEvents(
          AcpEventBatchPayload(
            acpId: "acp-1",
            sessionId: summary.sessionId,
            rawCount: 1,
            events: [
              AcpConversationEvent(
                timestamp: "2026-04-28T00:00:20Z",
                sequence: 9,
                kind: .object([
                  "type": .string("tool_invocation"),
                  "tool_name": .string("Read"),
                  "category": .string("read"),
                  "input": .object(["path": .string("README.md")]),
                  "invocation_id": .string("call-read"),
                ]),
                agent: "copilot",
                sessionId: summary.sessionId
              )
            ]
          )
        )
      )
    )

    let acpEntry = try #require(
      store.timeline.first { $0.entryId == "acp-copilot-tool_invocation-9" }
    )
    #expect(acpEntry.kind == "tool_invocation")
    #expect(acpEntry.summary == "copilot invoked Read")
    #expect(store.timelineWindow?.totalCount == 2)

    store.stopAllStreams()
  }
}

private func makeAcpPermissionBatch(
  batchID: String,
  acpID: String,
  sessionID: String,
  createdAt: String
) -> AcpPermissionBatch {
  AcpPermissionBatch(
    batchId: batchID,
    acpId: acpID,
    sessionId: sessionID,
    requests: [
      AcpPermissionItem(
        requestId: "\(batchID)-request",
        sessionId: sessionID,
        toolCall: .object([
          "kind": .string("write"),
          "path": .string("README.md"),
        ]),
        options: [.string("allow"), .string("deny")]
      )
    ],
    createdAt: createdAt
  )
}

private func makeAcpSnapshot(
  acpID: String,
  sessionID: String,
  pendingBatches: [AcpPermissionBatch]
) -> AcpAgentSnapshot {
  AcpAgentSnapshot(
    acpId: acpID,
    sessionId: sessionID,
    agentId: "copilot",
    displayName: "Copilot",
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
