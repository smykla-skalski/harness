import Foundation

extension PreviewHarnessClientState {
  func startAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) -> AcpAgentSnapshot {
    nextAcpAgentSequence += 1
    let snapshot = AcpAgentSnapshot(
      acpId: "preview-managed-agent-\(nextAcpAgentSequence)",
      sessionId: sessionID,
      agentId: request.agent,
      displayName: request.agent == "copilot" ? "GitHub Copilot" : request.agent.capitalized,
      status: .active,
      pid: UInt32(40_000 + nextAcpAgentSequence),
      pgid: Int32(40_000 + nextAcpAgentSequence),
      projectDir: request.projectDir ?? fallbackDetail?.session.projectDir
        ?? "/Users/example/Projects/harness",
      pendingPermissions: 0,
      permissionQueueDepth: 0,
      pendingPermissionBatches: [],
      terminalCount: 0,
      createdAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )
    var agents = acpAgentsBySessionID[sessionID] ?? []
    agents.insert(snapshot, at: 0)
    acpAgentsBySessionID[sessionID] = agents
    return snapshot
  }

  func resolveAcpPermission(
    agentID: String,
    batchID: String,
    decision _: AcpPermissionDecision
  ) -> AcpAgentSnapshot? {
    for (sessionID, agents) in acpAgentsBySessionID {
      guard let index = agents.firstIndex(where: { $0.acpId == agentID }) else {
        continue
      }
      let snapshot = agents[index]
      let batches = snapshot.pendingPermissionBatches.filter { $0.batchId != batchID }
      let updated = AcpAgentSnapshot(
        acpId: snapshot.acpId,
        sessionId: snapshot.sessionId,
        agentId: snapshot.agentId,
        displayName: snapshot.displayName,
        status: snapshot.status,
        pid: snapshot.pid,
        pgid: snapshot.pgid,
        projectDir: snapshot.projectDir,
        pendingPermissions: batches.reduce(0) { $0 + $1.requests.count },
        permissionQueueDepth: snapshot.permissionQueueDepth,
        pendingPermissionBatches: batches,
        terminalCount: snapshot.terminalCount,
        createdAt: snapshot.createdAt,
        updatedAt: Self.mutationTimestamp,
        disconnectReason: snapshot.disconnectReason,
        stderrTail: snapshot.stderrTail
      )
      var updatedAgents = agents
      updatedAgents[index] = updated
      acpAgentsBySessionID[sessionID] = updatedAgents
      return updated
    }
    return nil
  }

  func managedAgents(sessionID: String) -> [ManagedAgentSnapshot] {
    let terminals = (agentTuisBySessionID[sessionID] ?? []).map(ManagedAgentSnapshot.terminal)
    let codex = (codexRunsBySessionID[sessionID] ?? []).map(ManagedAgentSnapshot.codex)
    let acp = (acpAgentsBySessionID[sessionID] ?? []).map(ManagedAgentSnapshot.acp)
    return terminals + codex + acp
  }
}
