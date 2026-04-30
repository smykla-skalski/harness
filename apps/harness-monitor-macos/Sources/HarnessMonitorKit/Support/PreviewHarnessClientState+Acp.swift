import Foundation

extension PreviewHarnessClientState {
  func startAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) -> AcpAgentSnapshot {
    nextAcpAgentSequence += 1
    let permissionBatches = previewPermissionBatches(
      sessionID: sessionID,
      acpID: "preview-managed-agent-\(nextAcpAgentSequence)"
    )
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
      pendingPermissions: permissionBatches.reduce(0) { $0 + $1.requests.count },
      permissionQueueDepth: 0,
      pendingPermissionBatches: permissionBatches,
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
    let seedsPermission =
      ProcessInfo.processInfo.environment[
        "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"
      ] == "1"
      || ProcessInfo.processInfo.environment["HARNESS_MONITOR_PREVIEW_ACP_PENDING"] == "1"
    if seedsPermission,
      let detail = fallbackDetail,
      !detail.session.sessionId.isEmpty
    {
      let seededSnapshot = Self.seededAcpAgentSnapshot(
        sessionID: detail.session.sessionId,
        projectDir: detail.session.projectDir ?? "/Users/example/Projects/harness"
      )
      return AcpAgentSnapshot(
        acpId: seededSnapshot.acpId,
        sessionId: seededSnapshot.sessionId,
        agentId: seededSnapshot.agentId,
        displayName: seededSnapshot.displayName,
        status: seededSnapshot.status,
        pid: seededSnapshot.pid,
        pgid: seededSnapshot.pgid,
        projectDir: seededSnapshot.projectDir,
        pendingPermissions: 0,
        permissionQueueDepth: seededSnapshot.permissionQueueDepth,
        pendingPermissionBatches: [],
        terminalCount: seededSnapshot.terminalCount,
        createdAt: seededSnapshot.createdAt,
        updatedAt: Self.mutationTimestamp
      )
    }
    return nil
  }

  func managedAgents(sessionID: String) -> [ManagedAgentSnapshot] {
    let terminals = (agentTuisBySessionID[sessionID] ?? []).map(ManagedAgentSnapshot.terminal)
    let codex = (codexRunsBySessionID[sessionID] ?? []).map(ManagedAgentSnapshot.codex)
    let acp = (acpAgentsBySessionID[sessionID] ?? []).map(ManagedAgentSnapshot.acp)
    return terminals + codex + acp
  }

  func acpInspect(sessionID: String?) -> AcpAgentInspectResponse {
    let sessions =
      if let sessionID {
        [sessionID]
      } else {
        Array(acpAgentsBySessionID.keys)
      }

    let sortedAgents =
      sessions
      .flatMap { acpAgentsBySessionID[$0] ?? [] }
      .map(Self.inspectSnapshot(from:))
      .sorted {
        if $0.displayName != $1.displayName {
          return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return $0.acpId < $1.acpId
      }
    return AcpAgentInspectResponse(agents: sortedAgents)
  }

  static func inspectSnapshot(from snapshot: AcpAgentSnapshot) -> AcpAgentInspectSnapshot {
    let seedsPendingDeadline =
      ProcessInfo.processInfo.environment["HARNESS_MONITOR_PREVIEW_ACP_PENDING"] == "1"
      || ProcessInfo.processInfo.environment[
        "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"
      ] == "1"
    let permissionLogPath = previewAcpPermissionLogPath()
    return AcpAgentInspectSnapshot(
      acpId: snapshot.acpId,
      sessionId: snapshot.sessionId,
      agentId: snapshot.agentId,
      displayName: snapshot.displayName,
      pid: snapshot.pid,
      pgid: snapshot.pgid,
      uptimeMs: 93_000,
      lastUpdateAt: snapshot.updatedAt,
      lastClientCallAt: snapshot.updatedAt,
      watchdogState: "active",
      permissionMode: "allow_edits",
      permissionLogPath: permissionLogPath,
      pendingPermissions: snapshot.pendingPermissions,
      permissionQueueDepth: snapshot.permissionQueueDepth,
      terminalCount: snapshot.terminalCount,
      promptDeadlineRemainingMs: seedsPendingDeadline ? 95_000 : 0
    )
  }

  private static func previewAcpPermissionLogPath() -> String? {
    let key = "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_LOG_PATH"
    if let rawValue = getenv(key) {
      let value = String(cString: rawValue)
      return value.isEmpty || value == "__missing__" ? nil : value
    }
    return "/tmp/harness/permission-log.ndjson"
  }

  private func previewPermissionBatches(
    sessionID: String,
    acpID: String
  ) -> [AcpPermissionBatch] {
    guard
      ProcessInfo.processInfo.environment["HARNESS_MONITOR_PREVIEW_ACP_PENDING"] == "1"
        || ProcessInfo.processInfo.environment["HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"]
          == "1"
    else {
      return []
    }
    return [
      AcpPermissionBatch(
        batchId: "preview-acp-permission-1",
        acpId: acpID,
        sessionId: sessionID,
        requests: [
          AcpPermissionItem(
            requestId: "preview-request-write",
            sessionId: sessionID,
            toolCall: .object([
              "kind": .string("fs.write_text_file"),
              "path": .string("Sources/App.swift"),
            ]),
            options: []
          ),
          AcpPermissionItem(
            requestId: "preview-request-terminal",
            sessionId: sessionID,
            toolCall: .object([
              "kind": .string("terminal.create"),
              "command": .string("swift test"),
            ]),
            options: []
          ),
        ],
        createdAt: Self.mutationTimestamp
      )
    ]
  }
}
