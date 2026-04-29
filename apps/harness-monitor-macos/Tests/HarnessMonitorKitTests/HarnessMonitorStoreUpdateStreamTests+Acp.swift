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

    #expect(
      store.pendingAcpPermissionBatches.map(\.batchId) == ["batch-1", "batch-2"]
    )
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

  @Test("pending permission list prefers selected snapshot over late standalone duplicate")
  func pendingPermissionListPrefersSelectedSnapshotOverStandaloneDuplicate() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-precedence"

    let stale = makeAcpPermissionBatch(
      batchID: "batch-1",
      acpID: "acp-1",
      sessionID: "sess-acp-precedence",
      createdAt: "2026-04-28T00:00:01Z"
    )
    store.applyAcpPermissionBatch(stale)

    let fresh = AcpPermissionBatch(
      batchId: "batch-1",
      acpId: "acp-1",
      sessionId: "sess-acp-precedence",
      requests: [
        AcpPermissionItem(
          requestId: "request-selected",
          sessionId: "sess-acp-precedence",
          toolCall: .object(["kind": .string("write")]),
          options: [.string("allow")]
        )
      ],
      createdAt: "2026-04-28T00:00:02Z"
    )
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-precedence",
        pendingBatches: [fresh]
      )
    )

    #expect(store.pendingAcpPermissionBatches.count == 1)
    let requests = store.pendingAcpPermissionBatches.first?.requests.map(\.requestId)
    #expect(requests == ["request-selected"])
  }

  @Test("selected snapshot keeps newer permission batch when stale duplicate arrives later")
  func selectedSnapshotKeepsNewerBatchWhenStaleDuplicateArrivesLater() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-precedence"

    let fresh = AcpPermissionBatch(
      batchId: "batch-1",
      acpId: "acp-1",
      sessionId: "sess-acp-precedence",
      requests: [
        AcpPermissionItem(
          requestId: "request-selected",
          sessionId: "sess-acp-precedence",
          toolCall: .object(["kind": .string("write")]),
          options: [.string("allow")]
        )
      ],
      createdAt: "2026-04-28T00:00:02Z"
    )
    store.applyAcpAgent(
      makeAcpSnapshot(acpID: "acp-1", sessionID: "sess-acp-precedence", pendingBatches: [fresh])
    )

    let stale = makeAcpPermissionBatch(
      batchID: "batch-1",
      acpID: "acp-1",
      sessionID: "sess-acp-precedence",
      createdAt: "2026-04-28T00:00:01Z"
    )
    store.applyAcpPermissionBatch(stale)

    #expect(store.pendingAcpPermissionBatches.count == 1)
    let requests = store.pendingAcpPermissionBatches.first?.requests.map(\.requestId)
    #expect(requests == ["request-selected"])
  }

  @Test("ACP process incident appends timeline entry for selected session")
  func acpProcessIncidentAppendsTimelineEntryForSelectedSession() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-incident"

    store.applyAcpProcessIncident(
      AcpProcessIncidentPayload(
        kind: "transport_closed",
        reasonKind: "transport_closed",
        processKey: "acp-process-1",
        pid: UInt32(42),
        pgid: Int32(42),
        exitCode: nil,
        exitSignal: nil,
        stderrTail: "lost transport",
        affectedLogicalSessionIds: ["sess-acp-incident"]
      ),
      recordedAt: "2026-04-29T00:00:00Z",
      sessionID: "sess-acp-incident"
    )

    #expect(store.timeline.last?.kind == "acp_process_incident")
    #expect(store.timeline.last?.sessionId == "sess-acp-incident")
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
  displayName: String = "Copilot",
  pendingBatches: [AcpPermissionBatch]
) -> AcpAgentSnapshot {
  AcpAgentSnapshot(
    acpId: acpID,
    sessionId: sessionID,
    agentId: "copilot",
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
