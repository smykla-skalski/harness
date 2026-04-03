import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func createTask(
    sessionID: String,
    request: TaskCreateRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .createTask(
        sessionID: sessionID,
        title: request.title,
        context: request.context,
        severity: request.severity,
        actor: request.actor
      )
    )

    let task = WorkItem(
      taskId: "task-created",
      title: request.title,
      context: request.context,
      severity: request.severity,
      status: .open,
      assignedTo: nil,
      createdAt: "2026-03-28T14:19:00Z",
      updatedAt: "2026-03-28T14:19:00Z",
      createdBy: request.actor,
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil
    )
    detail = replacing(tasks: detail.tasks + [task])
    return detail
  }

  func assignTask(
    sessionID: String,
    taskID: String,
    request: TaskAssignRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .assignTask(
        sessionID: sessionID,
        taskID: taskID,
        agentID: request.agentId,
        actor: request.actor
      )
    )
    detail = replacingTask(taskID) { task in
      WorkItem(
        taskId: task.taskId,
        title: task.title,
        context: task.context,
        severity: task.severity,
        status: .inProgress,
        assignedTo: request.agentId,
        createdAt: task.createdAt,
        updatedAt: "2026-03-28T14:20:00Z",
        createdBy: task.createdBy,
        notes: task.notes,
        suggestedFix: task.suggestedFix,
        source: task.source,
        blockedReason: task.blockedReason,
        completedAt: task.completedAt,
        checkpointSummary: task.checkpointSummary
      )
    }
    return detail
  }

  func updateTask(
    sessionID: String,
    taskID: String,
    request: TaskUpdateRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .updateTask(
        sessionID: sessionID,
        taskID: taskID,
        status: request.status,
        note: request.note,
        actor: request.actor
      )
    )
    detail = replacingTask(taskID) { task in
      WorkItem(
        taskId: task.taskId,
        title: task.title,
        context: task.context,
        severity: task.severity,
        status: request.status,
        assignedTo: task.assignedTo,
        createdAt: task.createdAt,
        updatedAt: "2026-03-28T14:21:00Z",
        createdBy: task.createdBy,
        notes: task.notes + note(from: request),
        suggestedFix: task.suggestedFix,
        source: task.source,
        blockedReason: task.blockedReason,
        completedAt: request.status == .done ? "2026-03-28T14:21:00Z" : task.completedAt,
        checkpointSummary: task.checkpointSummary
      )
    }
    return detail
  }

  func checkpointTask(
    sessionID: String,
    taskID: String,
    request: TaskCheckpointRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .checkpointTask(
        sessionID: sessionID,
        taskID: taskID,
        summary: request.summary,
        progress: request.progress,
        actor: request.actor
      )
    )
    detail = replacingTask(taskID) { task in
      WorkItem(
        taskId: task.taskId,
        title: task.title,
        context: task.context,
        severity: task.severity,
        status: task.status,
        assignedTo: task.assignedTo,
        createdAt: task.createdAt,
        updatedAt: "2026-03-28T14:22:00Z",
        createdBy: task.createdBy,
        notes: task.notes,
        suggestedFix: task.suggestedFix,
        source: task.source,
        blockedReason: task.blockedReason,
        completedAt: task.completedAt,
        checkpointSummary: TaskCheckpointSummary(
          checkpointId: "\(task.taskId)-cp",
          recordedAt: "2026-03-28T14:22:00Z",
          actorId: request.actor,
          summary: request.summary,
          progress: request.progress
        )
      )
    }
    return detail
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
        runtimeCapabilities: agent.runtimeCapabilities
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

extension RecordingHarnessClient {
  fileprivate func replacing(tasks: [WorkItem]) -> SessionDetail {
    SessionDetail(
      session: updatedSession(),
      agents: detail.agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )
  }

  fileprivate func replacingTask(
    _ taskID: String,
    transform: (WorkItem) -> WorkItem
  ) -> SessionDetail {
    let tasks = detail.tasks.map { task in
      task.taskId == taskID ? transform(task) : task
    }
    return SessionDetail(
      session: updatedSession(),
      agents: detail.agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )
  }

  fileprivate func replacingAgent(
    _ agentID: String,
    transform: (AgentRegistration) -> AgentRegistration
  ) -> SessionDetail {
    let agents = detail.agents.map { agent in
      agent.agentId == agentID ? transform(agent) : agent
    }
    let updatedAgent = agents.first { $0.agentId == agentID }
    return SessionDetail(
      session: updatedSession(),
      agents: agents,
      tasks: detail.tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity.map { activity in
        activity.agentId == agentID
          ? AgentToolActivitySummary(
            agentId: updatedAgent?.agentId ?? activity.agentId,
            runtime: updatedAgent?.runtime ?? activity.runtime,
            toolInvocationCount: activity.toolInvocationCount,
            toolResultCount: activity.toolResultCount,
            toolErrorCount: activity.toolErrorCount,
            latestToolName: activity.latestToolName,
            latestEventAt: activity.latestEventAt,
            recentTools: activity.recentTools
          )
          : activity
      }
    )
  }

  fileprivate func updatedSession() -> SessionSummary {
    SessionSummary(
      projectId: detail.session.projectId,
      projectName: detail.session.projectName,
      projectDir: detail.session.projectDir,
      contextRoot: detail.session.contextRoot,
      sessionId: detail.session.sessionId,
      context: detail.session.context,
      status: detail.session.status,
      createdAt: detail.session.createdAt,
      updatedAt: "2026-03-28T14:24:00Z",
      lastActivityAt: "2026-03-28T14:24:00Z",
      leaderId: detail.session.leaderId,
      observeId: detail.session.observeId,
      pendingLeaderTransfer: detail.session.pendingLeaderTransfer,
      metrics: detail.session.metrics
    )
  }

  fileprivate func note(from request: TaskUpdateRequest) -> [TaskNote] {
    guard let note = request.note else {
      return []
    }
    return [
      TaskNote(
        timestamp: "2026-03-28T14:21:00Z",
        agentId: request.actor,
        text: note
      )
    ]
  }
}
