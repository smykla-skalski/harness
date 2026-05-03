import Foundation

extension PreviewHarnessClientState {
  func startAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) -> AcpAgentSnapshot {
    nextAcpAgentSequence += 1
    let trimmedName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName =
      if let trimmedName, !trimmedName.isEmpty {
        trimmedName
      } else if request.agent == "copilot" {
        "GitHub Copilot"
      } else {
        request.agent.capitalized
      }
    let permissionBatches = previewPermissionBatches(
      sessionID: sessionID,
      acpID: "preview-managed-agent-\(nextAcpAgentSequence)"
    )
    let snapshot = AcpAgentSnapshot(
      acpId: "preview-managed-agent-\(nextAcpAgentSequence)",
      sessionId: sessionID,
      agentId: request.agent,
      displayName: displayName,
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
    applyStartedAcpAgent(snapshot, request: request)
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
    let seedsPermission = Self.seedsPendingAcp(in: environment)
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
      .map { Self.inspectSnapshot(from: $0, environment: environment) }
      .sorted {
        if $0.displayName != $1.displayName {
          return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return $0.acpId < $1.acpId
      }
    return AcpAgentInspectResponse(agents: sortedAgents)
  }

  static func inspectSnapshot(
    from snapshot: AcpAgentSnapshot,
    environment: HarnessMonitorEnvironment = .current
  ) -> AcpAgentInspectSnapshot {
    let seedsPendingDeadline = Self.seedsPendingAcp(in: environment)
    let permissionLogPath = previewAcpPermissionLogPath(environment: environment)
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

  private static func previewAcpPermissionLogPath(
    environment: HarnessMonitorEnvironment
  ) -> String? {
    let key = "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_LOG_PATH"
    let value = environment.values[key]
    if let value {
      return value.isEmpty || value == "__missing__" ? nil : value
    }
    return "/tmp/harness/permission-log.ndjson"
  }

  private func previewPermissionBatches(
    sessionID: String,
    acpID: String
  ) -> [AcpPermissionBatch] {
    guard Self.seedsPendingAcp(in: environment) else {
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

  private func applyStartedAcpAgent(
    _ snapshot: AcpAgentSnapshot,
    request: AcpAgentStartRequest
  ) {
    guard let currentDetail = currentMutableSessionDetail(sessionID: snapshot.sessionId) else {
      return
    }

    let assignedRole = startedAcpRole(for: request, currentDetail: currentDetail)
    let registration = previewAcpRegistration(
      from: snapshot,
      request: request,
      assignedRole: assignedRole
    )
    let updatedAgents = currentDetail.agents.filter { $0.agentId != request.agent } + [registration]
    let updatedSummary = SessionSummary(
      projectId: currentDetail.session.projectId,
      projectName: currentDetail.session.projectName,
      projectDir: currentDetail.session.projectDir,
      contextRoot: currentDetail.session.contextRoot,
      sessionId: currentDetail.session.sessionId,
      worktreePath: currentDetail.session.worktreePath,
      sharedPath: currentDetail.session.sharedPath,
      originPath: currentDetail.session.originPath,
      branchRef: currentDetail.session.branchRef,
      title: currentDetail.session.title,
      context: currentDetail.session.context,
      status: currentDetail.session.status,
      createdAt: currentDetail.session.createdAt,
      updatedAt: snapshot.updatedAt,
      lastActivityAt: snapshot.updatedAt,
      leaderId: assignedRole == .leader ? request.agent : currentDetail.session.leaderId,
      observeId: currentDetail.session.observeId,
      pendingLeaderTransfer: currentDetail.session.pendingLeaderTransfer,
      externalOrigin: currentDetail.session.externalOrigin,
      adoptedAt: currentDetail.session.adoptedAt,
      metrics: SessionMetrics(tasks: currentDetail.tasks, agents: updatedAgents)
    )
    let updatedDetail = SessionDetail(
      session: updatedSummary,
      agents: updatedAgents,
      tasks: currentDetail.tasks,
      signals: currentDetail.signals,
      observer: currentDetail.observer,
      agentActivity: currentDetail.agentActivity
    ).canonicallySorted()

    storeMutatedSessionDetail(updatedDetail)
  }

  private func startedAcpRole(
    for request: AcpAgentStartRequest,
    currentDetail: SessionDetail
  ) -> SessionRole {
    if request.role == .leader,
      let fallbackRole = request.fallbackRole,
      let leaderID = currentDetail.session.leaderId,
      leaderID != request.agent
    {
      return fallbackRole
    }
    return request.role
  }

  private func previewAcpRegistration(
    from snapshot: AcpAgentSnapshot,
    request: AcpAgentStartRequest,
    assignedRole: SessionRole
  ) -> AgentRegistration {
    let runtimeCapabilities = RuntimeCapabilities(
      runtime: request.agent,
      supportsNativeTranscript: true,
      supportsSignalDelivery: true,
      supportsContextInjection: true,
      typicalSignalLatencySeconds: 5,
      hookPoints: []
    )
    return AgentRegistration(
      agentId: request.agent,
      name: snapshot.displayName,
      runtime: request.agent,
      role: assignedRole,
      capabilities: request.capabilities,
      joinedAt: snapshot.createdAt,
      updatedAt: snapshot.updatedAt,
      status: snapshot.status,
      agentSessionId: nil,
      lastActivityAt: snapshot.updatedAt,
      currentTaskId: nil,
      runtimeCapabilities: runtimeCapabilities,
      persona: nil
    )
  }
}
