import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func createTask(
    sessionID: String,
    request: TaskCreateRequest
  ) async throws -> SessionDetail {
    recordActiveTraceContext(operation: "createTask")
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

  func dropTask(
    sessionID: String,
    taskID: String,
    request: TaskDropRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .dropTask(
        sessionID: sessionID,
        taskID: taskID,
        target: request.target,
        queuePolicy: request.queuePolicy,
        actor: request.actor
      )
    )

    detail = replacingTask(taskID) { task in
      let agentID: String
      switch request.target {
      case .agent(let droppedAgentID):
        agentID = droppedAgentID
      }
      return WorkItem(
        taskId: task.taskId,
        title: task.title,
        context: task.context,
        severity: task.severity,
        status: .inProgress,
        assignedTo: agentID,
        queuePolicy: .locked,
        queuedAt: nil,
        createdAt: task.createdAt,
        updatedAt: "2026-03-28T14:20:30Z",
        createdBy: task.createdBy,
        notes: task.notes,
        suggestedFix: task.suggestedFix,
        source: task.source,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: task.checkpointSummary
      )
    }
    return detail
  }

  func updateTaskQueuePolicy(
    sessionID: String,
    taskID: String,
    request: TaskQueuePolicyRequest
  ) async throws -> SessionDetail {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .updateTaskQueuePolicy(
        sessionID: sessionID,
        taskID: taskID,
        queuePolicy: request.queuePolicy,
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
        queuePolicy: request.queuePolicy,
        queuedAt: task.queuedAt,
        createdAt: task.createdAt,
        updatedAt: "2026-03-28T14:20:45Z",
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
}
