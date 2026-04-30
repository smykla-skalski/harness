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
    lock.withLock {
      let assignedRole =
        if request.role == .leader,
          let fallbackRole = request.fallbackRole,
          let existingSession =
            sessionDetailsByID[sessionID]
            ?? (detailStorage.session.sessionId == sessionID ? detailStorage : nil),
          existingSession.session.leaderId != nil,
          existingSession.session.leaderId != request.agent
        {
          fallbackRole
        } else {
          request.role
        }
      let currentDetail = sessionDetailsByID[sessionID] ?? detailStorage
      let runtimeCapabilities = RuntimeCapabilities(
        runtime: request.agent,
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 5,
        hookPoints: []
      )
      let registration = AgentRegistration(
        agentId: request.agent,
        name: request.name ?? defaultDisplayName,
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
        metrics: SessionMetrics(
          agentCount: currentDetail.agents.contains(where: { $0.agentId == request.agent })
            ? currentDetail.session.metrics.agentCount
            : currentDetail.session.metrics.agentCount + 1,
          activeAgentCount: currentDetail.agents.contains(where: { $0.agentId == request.agent })
            ? currentDetail.session.metrics.activeAgentCount
            : currentDetail.session.metrics.activeAgentCount + 1,
          openTaskCount: currentDetail.session.metrics.openTaskCount,
          inProgressTaskCount: currentDetail.session.metrics.inProgressTaskCount,
          blockedTaskCount: currentDetail.session.metrics.blockedTaskCount,
          completedTaskCount: currentDetail.session.metrics.completedTaskCount
        )
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
    return .acp(snapshot)
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
