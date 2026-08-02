import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Dashboard ACP agent management")
@MainActor
struct DashboardAcpAgentManagementTests {
  @Test("Dashboard creates, resolves, observes transcript, and stops an ACP agent")
  func dashboardAcpLifecycleEndToEnd() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let session = PreviewFixtures.summary
    let started = try #require(
      await store.startDashboardAcpAgent(
        descriptorID: AcpDescriptorID(rawValue: "copilot"),
        sessionID: session.sessionId,
        projectDirectory: session.checkoutRoot,
        name: "Dashboard ACP",
        prompt: "Inspect the dashboard"
      )
    )
    let batch = permissionBatch(agent: started)
    let waiting = client.replacingAcpSnapshot(started, pendingBatches: [batch])
    client.lock.withLock {
      client.resolvedAcpSnapshotsByAgentID[started.managedAgentID] = waiting
      client.acpInspectResponsesBySessionID[session.sessionId] = [
        AcpAgentInspectResponse(agents: [inspectSnapshot(agent: waiting)])
      ]
    }

    let pendingDetail = await detail(store: store, agent: waiting, session: session)
    #expect(pendingDetail.pendingPermissions.map(\.batchId) == [batch.batchId])
    #expect(pendingDetail.continuity.title == "Resumable")

    #expect(await store.resolveAcpPermission(batch: batch, decision: .approveAll))
    let transcriptEntry = TimelineEntry(
      entryId: "dashboard-acp-transcript",
      recordedAt: "2026-08-02T12:00:00Z",
      kind: "agent_message",
      sessionId: session.sessionId,
      agentId: started.sessionAgentID,
      taskId: nil,
      summary: "Dashboard transcript updated",
      payload: .null
    )
    client.configureAcpTranscriptResponse(
      AcpTranscriptResponse(entries: [transcriptEntry]),
      for: session.sessionId
    )

    let updatedDetail = await detail(store: store, agent: waiting, session: session)
    #expect(updatedDetail.pendingPermissions.isEmpty)
    #expect(updatedDetail.transcript.map(\.entryId) == [transcriptEntry.entryId])

    let stopped = try #require(
      await store.stopDashboardAcpAgent(agentID: started.managedAgentID)
    )
    let stoppedDetail = await detail(store: store, agent: stopped, session: session)
    #expect(stoppedDetail.agent?.status == .removed)
    #expect(stoppedDetail.continuity.title == "Stopped")
  }

  private func detail(
    store: HarnessMonitorStore,
    agent: AcpAgentSnapshot,
    session: SessionSummary
  ) async -> DashboardAcpAgentDetail {
    await store.dashboardAcpAgentDetail(
      managedAgentID: agent.managedAgentID,
      sessionID: session.sessionId,
      sessionAgentID: agent.sessionAgentID,
      projectDirectory: session.checkoutRoot
    )
  }

  private func permissionBatch(agent: AcpAgentSnapshot) -> AcpPermissionBatch {
    AcpPermissionBatch(
      batchId: "dashboard-batch",
      acpId: agent.managedAgentID,
      sessionId: agent.sessionId,
      requests: [
        AcpPermissionItem(
          requestId: "dashboard-request",
          sessionId: agent.sessionId,
          toolCall: .object(["kind": .string("write"), "path": .string("README.md")]),
          options: [.string("allow"), .string("deny")]
        )
      ],
      createdAt: "2026-08-02T11:59:00Z"
    )
  }

  private func inspectSnapshot(agent: AcpAgentSnapshot) -> AcpAgentInspectSnapshot {
    AcpAgentInspectSnapshot(
      acpId: agent.managedAgentID,
      sessionId: agent.sessionId,
      agentId: agent.sessionAgentID,
      displayName: agent.displayName,
      pid: agent.pid,
      pgid: agent.pgid,
      uptimeMs: 2_000,
      lastUpdateAt: agent.updatedAt,
      lastClientCallAt: agent.updatedAt,
      watchdogState: "ready",
      pendingPermissions: agent.pendingPermissions,
      permissionQueueDepth: agent.permissionQueueDepth,
      terminalCount: 0,
      promptDeadlineRemainingMs: 30_000,
      handshake: AcpAgentHandshake(
        protocolVersion: 1,
        authMethodIds: ["oauth"],
        supportsLoadSession: true,
        supportsSessionResume: true,
        supportsLogout: true
      ),
      sessionState: AcpAgentSessionState(title: "Dashboard migration")
    )
  }
}
