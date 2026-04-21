import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func adoptSession(bookmarkID: String?, sessionRoot: URL) async throws -> SessionSummary {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(.adoptSession(bookmarkID: bookmarkID, sessionRoot: sessionRoot))
    return SessionSummary(
      projectId: detail.session.projectId,
      projectName: detail.session.projectName,
      projectDir: detail.session.projectDir,
      contextRoot: detail.session.contextRoot,
      sessionId: "sess-adopted",
      title: "",
      context: "",
      status: .active,
      createdAt: "2026-04-20T12:00:00Z",
      updatedAt: "2026-04-20T12:00:00Z",
      lastActivityAt: nil,
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 0,
        activeAgentCount: 0,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      )
    )
  }

  func startSession(request: SessionStartRequest) async throws -> SessionSummary {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .startSession(
        projectDir: request.projectDir,
        runtime: request.runtime,
        baseRef: request.baseRef
      )
    )
    return SessionSummary(
      projectId: detail.session.projectId,
      projectName: detail.session.projectName,
      projectDir: request.projectDir,
      contextRoot: detail.session.contextRoot,
      sessionId: request.sessionId ?? "sess-recording-new",
      title: request.title,
      context: request.context,
      status: .active,
      createdAt: "2026-04-20T12:00:00Z",
      updatedAt: "2026-04-20T12:00:00Z",
      lastActivityAt: nil,
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 0,
        activeAgentCount: 0,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      )
    )
  }

  func changeRole(
    sessionID: String,
    agentID: String,
    request: RoleChangeRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .changeRole(
        sessionID: sessionID,
        agentID: agentID,
        role: request.role,
        actor: request.actor
      )
    )
    detail = replacingAgent(agentID) { agent in
      AgentRegistration(
        agentId: agent.agentId,
        name: agent.name,
        runtime: agent.runtime,
        role: request.role,
        capabilities: agent.capabilities,
        joinedAt: agent.joinedAt,
        updatedAt: "2026-03-28T14:23:00Z",
        status: agent.status,
        agentSessionId: agent.agentSessionId,
        lastActivityAt: agent.lastActivityAt,
        currentTaskId: agent.currentTaskId,
        runtimeCapabilities: agent.runtimeCapabilities,
        persona: agent.persona
      )
    }
    return detail
  }

  func removeAgent(
    sessionID: String,
    agentID: String,
    request: AgentRemoveRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .removeAgent(
        sessionID: sessionID,
        agentID: agentID,
        actor: request.actor
      )
    )
    detail = SessionDetail(
      session: updatedSession(),
      agents: detail.agents.filter { $0.agentId != agentID },
      tasks: detail.tasks.map { task in
        guard task.assignedTo == agentID else {
          return task
        }
        return WorkItem(
          taskId: task.taskId,
          title: task.title,
          context: task.context,
          severity: task.severity,
          status: .open,
          assignedTo: nil,
          createdAt: task.createdAt,
          updatedAt: "2026-03-28T14:23:30Z",
          createdBy: task.createdBy,
          notes: task.notes,
          suggestedFix: task.suggestedFix,
          source: task.source,
          blockedReason: nil,
          completedAt: nil,
          checkpointSummary: task.checkpointSummary
        )
      },
      signals: detail.signals.filter { $0.agentId != agentID },
      observer: detail.observer,
      agentActivity: detail.agentActivity.filter { $0.agentId != agentID }
    )
    return detail
  }

  func transferLeader(
    sessionID: String,
    request: LeaderTransferRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .transferLeader(
        sessionID: sessionID,
        newLeaderID: request.newLeaderId,
        reason: request.reason,
        actor: request.actor
      )
    )
    detail = SessionDetail(
      session: SessionSummary(
        projectId: detail.session.projectId,
        projectName: detail.session.projectName,
        projectDir: detail.session.projectDir,
        contextRoot: detail.session.contextRoot,
        sessionId: detail.session.sessionId,
        title: detail.session.title,
        context: detail.session.context,
        status: detail.session.status,
        createdAt: detail.session.createdAt,
        updatedAt: "2026-03-28T14:24:00Z",
        lastActivityAt: detail.session.lastActivityAt,
        leaderId: request.newLeaderId,
        observeId: detail.session.observeId,
        pendingLeaderTransfer: nil,
        metrics: detail.session.metrics
      ),
      agents: detail.agents,
      tasks: detail.tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )
    return detail
  }
}
