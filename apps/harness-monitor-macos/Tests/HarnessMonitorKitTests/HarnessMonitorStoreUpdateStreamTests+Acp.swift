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

  @Test("ACP inspect unavailable marks runtime telemetry unavailable")
  func acpInspectUnavailableMarksRuntimeTelemetryUnavailable() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-unavailable"
    store.selectedAcpAgents = [
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-unavailable",
        agentID: "worker",
        displayName: "Worker",
        pendingBatches: []
      )
    ]

    store.replaceAcpInspect(
      AcpAgentInspectResponse(
        agents: [],
        available: false,
        issueMessage: "ACP inspect unavailable."
      ),
      sessionID: "sess-acp-unavailable",
      sampledAt: Date(timeIntervalSince1970: 15)
    )

    #expect(store.acpRuntimeInspectStatus(for: "worker")?.phase == .unavailable)
  }

  @Test("ACP inspect unavailable replaces stale telemetry and recovers on the next good sample")
  func acpInspectUnavailableReplacesStaleTelemetryAndRecovers() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-recovery"
    store.selectedAcpAgents = [
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-recovery",
        agentID: "worker",
        displayName: "Worker",
        pendingBatches: []
      )
    ]
    store.selectedAcpInspectState = AcpInspectSample(
      sessionID: "sess-acp-recovery",
      sampledAt: Date(timeIntervalSince1970: 16),
      agents: [
        makeAcpInspectSnapshot(
          acpID: "acp-1",
          sessionID: "sess-acp-recovery",
          agentID: "worker",
          displayName: "Worker Inspect"
        )
      ]
    )

    store.replaceAcpInspect(
      AcpAgentInspectResponse(
        agents: [],
        available: false,
        issueMessage: "ACP inspect unavailable."
      ),
      sessionID: "sess-acp-recovery",
      sampledAt: Date(timeIntervalSince1970: 17)
    )

    #expect(store.selectedAcpInspectAgents.isEmpty)
    #expect(store.acpRuntimeState(for: "worker")?.inspect == nil)
    #expect(store.acpRuntimeState(for: "worker")?.watchdogDisplayState == "unknown")
    #expect(store.acpRuntimeInspectStatus(for: "worker")?.phase == .unavailable)

    store.replaceAcpInspect(
      AcpAgentInspectResponse(
        agents: [
          makeAcpInspectSnapshot(
            acpID: "acp-1",
            sessionID: "sess-acp-recovery",
            agentID: "worker",
            displayName: "Worker Inspect Recovered"
          )
        ]
      ),
      sessionID: "sess-acp-recovery",
      sampledAt: Date(timeIntervalSince1970: 18)
    )

    #expect(
      store.acpRuntimeState(for: "worker")?.inspect?.displayName == "Worker Inspect Recovered"
    )
    #expect(store.acpRuntimeInspectStatus(for: "worker")?.phase == .ready)
  }

  @Test("ACP reconcile inline unavailable inspect clears stale telemetry")
  func acpReconcileInlineUnavailableInspectClearsStaleTelemetry() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-reconcile-unavailable"
    store.selectedAcpInspectState = AcpInspectSample(
      sessionID: "sess-acp-reconcile-unavailable",
      sampledAt: Date(timeIntervalSince1970: 19),
      agents: [
        makeAcpInspectSnapshot(
          acpID: "acp-1",
          sessionID: "sess-acp-reconcile-unavailable",
          agentID: "worker",
          displayName: "Worker Inspect"
        )
      ]
    )

    store.replaceAcpAgents(
      AcpAgentsReconciledPayload(
        sessionId: "sess-acp-reconcile-unavailable",
        agents: [
          makeAcpSnapshot(
            acpID: "acp-1",
            sessionID: "sess-acp-reconcile-unavailable",
            agentID: "worker",
            displayName: "Worker Snapshot",
            pendingBatches: []
          )
        ],
        inspect: AcpAgentInspectResponse(
          agents: [],
          available: false,
          issueMessage: "ACP inspect unavailable."
        )
      ),
      sampledAt: Date(timeIntervalSince1970: 20)
    )

    #expect(store.selectedAcpInspectAgents.isEmpty)
    #expect(store.acpRuntimeState(for: "worker")?.inspect == nil)
    #expect(store.acpRuntimeInspectStatus(for: "worker")?.phase == .unavailable)
  }

  @Test("ACP inspect retry falls back to stalled telemetry state")
  func acpInspectRetryFallsBackToStalledTelemetryState() async {
    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.client = client
    store.selectedSessionID = "sess-acp-stalled"
    store.acpInspectGracePeriod = .zero
    store.acpInspectRecoveryDelays = [.zero]

    store.replaceAcpAgents(
      AcpAgentsReconciledPayload(
        sessionId: "sess-acp-stalled",
        agents: [
          makeAcpSnapshot(
            acpID: "acp-1",
            sessionID: "sess-acp-stalled",
            agentID: "worker",
            displayName: "Worker",
            pendingBatches: []
          )
        ]
      )
    )

    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.acpRuntimeInspectStatus(for: "worker")?.phase == .stalled)
    #expect(client.acpInspectCallCount(for: "sess-acp-stalled") >= 1)
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

  @Test("ACP inspect push replaces selected runtime telemetry and clears with selection reset")
  func acpInspectPushReplacesSelectedRuntimeTelemetry() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-inspect"

    store.applySessionPushEvent(
      DaemonPushEvent(
        recordedAt: "2026-04-28T00:00:45Z",
        sessionId: "sess-acp-inspect",
        kind: .acpInspect(
          AcpAgentInspectResponse(
            agents: [
              makeAcpInspectSnapshot(
                acpID: "zeta-agent",
                sessionID: "sess-acp-inspect",
                agentID: "zeta-agent",
                displayName: "Zeta Agent"
              ),
              makeAcpInspectSnapshot(
                acpID: "alpha-agent",
                sessionID: "sess-acp-inspect",
                agentID: "alpha-agent",
                displayName: "Alpha Agent",
                promptDeadlineRemainingMs: 42_000
              ),
            ]
          )
        )
      )
    )

    #expect(store.selectedAcpInspectAgents.map(\.agentId) == ["alpha-agent", "zeta-agent"])
    #expect(
      store.acpInspectSnapshot(for: "alpha-agent")?.promptDeadlineRemainingMs == UInt64(42_000)
    )
    let sampledAt = HarnessMonitorStore.acpInspectSampledAt(from: "2026-04-28T00:00:45Z")
    #expect(store.selectedAcpInspectObservedAt == sampledAt)
    #expect(store.acpRuntimeState(for: "alpha-agent")?.promptDeadlineAnchorAt == sampledAt)

    store.resetSelectedAcpAgents()

    #expect(store.selectedAcpInspectAgents.isEmpty)
    #expect(store.selectedAcpInspectObservedAt == nil)
  }

}

func makeAcpPermissionBatch(
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

func makeAcpSnapshot(
  acpID: String,
  sessionID: String,
  agentID: String = "copilot",
  displayName: String = "Copilot",
  pendingBatches: [AcpPermissionBatch]
) -> AcpAgentSnapshot {
  AcpAgentSnapshot(
    acpId: acpID,
    sessionId: sessionID,
    agentId: agentID,
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

func makeAcpInspectSnapshot(
  acpID: String,
  sessionID: String,
  agentID: String,
  displayName: String,
  promptDeadlineRemainingMs: UInt64 = 0
) -> AcpAgentInspectSnapshot {
  AcpAgentInspectSnapshot(
    acpId: acpID,
    sessionId: sessionID,
    agentId: agentID,
    displayName: displayName,
    pid: UInt32(41_001),
    pgid: Int32(41_001),
    uptimeMs: 93_000,
    lastUpdateAt: "2026-04-28T00:00:40Z",
    lastClientCallAt: "2026-04-28T00:00:35Z",
    watchdogState: "active",
    permissionMode: "allow_edits",
    pendingPermissions: 2,
    permissionQueueDepth: 1,
    terminalCount: 1,
    promptDeadlineRemainingMs: promptDeadlineRemainingMs
  )
}
