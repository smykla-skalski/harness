import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse {
    let terminalAgents = configuredAgentTuis(for: sessionID).map(ManagedAgentSnapshot.terminal)
    let codexAgents = configuredCodexRuns(for: sessionID).map(ManagedAgentSnapshot.codex)
    let acpAgents = configuredAcpSnapshots(for: sessionID).map(ManagedAgentSnapshot.acp)
    return ManagedAgentListResponse(
      agents: terminalAgents + codexAgents + acpAgents
    )
  }

  func acpInspect(sessionID: String?) async throws -> AcpAgentInspectResponse {
    recordAcpInspectCall(for: sessionID)
    if let response = dequeueConfiguredAcpInspectResponse(for: sessionID) {
      return response
    }
    let snapshots = configuredAcpSnapshots(for: sessionID)
    return AcpAgentInspectResponse(
      agents: snapshots.map { snapshot in
        AcpAgentInspectSnapshot(
          acpId: snapshot.acpId,
          sessionId: snapshot.sessionId,
          agentId: snapshot.agentId,
          displayName: snapshot.displayName,
          pid: snapshot.pid,
          pgid: snapshot.pgid,
          uptimeMs: 0,
          lastUpdateAt: snapshot.updatedAt,
          lastClientCallAt: nil,
          watchdogState: "ready",
          pendingPermissions: snapshot.pendingPermissions,
          permissionQueueDepth: snapshot.permissionQueueDepth,
          terminalCount: snapshot.terminalCount,
          promptDeadlineRemainingMs: 0
        )
      }
    )
  }

  func startManagedAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) async throws -> ManagedAgentSnapshot {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .startAcpAgent(
        sessionID: sessionID,
        agentID: request.agent,
        role: request.role,
        fallbackRole: request.fallbackRole,
        capabilities: request.capabilities,
        name: request.name,
        prompt: request.prompt,
        projectDir: request.projectDir,
        persona: request.persona,
        recordPermissions: request.recordPermissions
      )
    )
    if let error = dequeueConfiguredAcpStartError() {
      throw error
    }
    let startedCount =
      recordedCalls().reduce(into: 0) { count, call in
        if case .startAcpAgent = call {
          count += 1
        }
      }
    let defaultDisplayName =
      if request.agent == "copilot" {
        "GitHub Copilot"
      } else {
        request.agent.capitalized
      }
    let snapshot = makeAcpSnapshot(
      acpID: "acp-\(startedCount)",
      sessionID: sessionID,
      agentID: request.agent,
      displayName: request.name ?? defaultDisplayName,
      pendingBatches: []
    )
    recordStartedAcpAgent(
      sessionID: sessionID,
      request: request,
      displayName: request.name ?? defaultDisplayName,
      snapshot: snapshot
    )
    return .acp(snapshot)
  }

  private func recordStartedAcpAgent(
    sessionID: String,
    request: AcpAgentStartRequest,
    displayName: String,
    snapshot: AcpAgentSnapshot
  ) {
    lock.withLock {
      let assignedRole = resolvedRoleForStartedAgent(
        sessionID: sessionID,
        request: request
      )
      let currentDetail = sessionDetailsByID[sessionID] ?? detailStorage
      let registration = startedAgentRegistration(
        request: request,
        displayName: displayName,
        assignedRole: assignedRole,
        snapshot: snapshot
      )
      let updatedSummary = updatedSummaryForStartedAgent(
        request: request,
        assignedRole: assignedRole,
        snapshot: snapshot,
        currentDetail: currentDetail
      )
      let updatedDetail = SessionDetail(
        session: updatedSummary,
        agents: currentDetail.agents.filter { $0.agentId != request.agent } + [registration],
        tasks: currentDetail.tasks,
        signals: currentDetail.signals,
        observer: currentDetail.observer,
        agentActivity: currentDetail.agentActivity
      ).canonicallySorted()
      if detailStorage.session.sessionId == sessionID {
        detailStorage = updatedDetail
      }
      sessionDetailsByID[sessionID] = updatedDetail
      if var summaries = sessionSummariesStorage,
        let index = summaries.firstIndex(where: { $0.sessionId == sessionID })
      {
        summaries[index] = updatedSummary
        sessionSummariesStorage = summaries
      }
      resolvedAcpSnapshotsByAgentID[snapshot.acpId] = snapshot
      resolvedAcpSnapshotsByAgentID[snapshot.agentId] = snapshot
    }
  }

  private func resolvedRoleForStartedAgent(
    sessionID: String,
    request: AcpAgentStartRequest
  ) -> SessionRole {
    if request.role == .leader,
      let fallbackRole = request.fallbackRole,
      let existingSession =
        sessionDetailsByID[sessionID]
        ?? (detailStorage.session.sessionId == sessionID ? detailStorage : nil),
      existingSession.session.leaderId != nil,
      existingSession.session.leaderId != request.agent
    {
      return fallbackRole
    }
    return request.role
  }

  private func startedAgentRegistration(
    request: AcpAgentStartRequest,
    displayName: String,
    assignedRole: SessionRole,
    snapshot: AcpAgentSnapshot
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
      name: displayName,
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

  private func updatedSummaryForStartedAgent(
    request: AcpAgentStartRequest,
    assignedRole: SessionRole,
    snapshot: AcpAgentSnapshot,
    currentDetail: SessionDetail
  ) -> SessionSummary {
    let alreadyPresent = currentDetail.agents.contains { $0.agentId == request.agent }
    return SessionSummary(
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
      metrics: SessionMetrics(
        agentCount: alreadyPresent
          ? currentDetail.session.metrics.agentCount
          : currentDetail.session.metrics.agentCount + 1,
        activeAgentCount: alreadyPresent
          ? currentDetail.session.metrics.activeAgentCount
          : currentDetail.session.metrics.activeAgentCount + 1,
        openTaskCount: currentDetail.session.metrics.openTaskCount,
        inProgressTaskCount: currentDetail.session.metrics.inProgressTaskCount,
        blockedTaskCount: currentDetail.session.metrics.blockedTaskCount,
        completedTaskCount: currentDetail.session.metrics.completedTaskCount
      )
    )
  }

  private func configuredAcpSnapshots(for sessionID: String?) -> [AcpAgentSnapshot] {
    lock.withLock {
      var seenAcpIDs = Set<String>()
      return resolvedAcpSnapshotsByAgentID.values.compactMap { snapshot in
        guard sessionID == nil || snapshot.sessionId == sessionID else {
          return nil
        }
        guard seenAcpIDs.insert(snapshot.acpId).inserted else {
          return nil
        }
        return snapshot
      }
      .sorted { $0.updatedAt > $1.updatedAt }
    }
  }
}
