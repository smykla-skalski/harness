import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func createTask(
    title: String,
    context: String?,
    severity: TaskSeverity,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Create task"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.createTask(sessionID: action.sessionID).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.createTask(
          sessionID: action.sessionID,
          request: TaskCreateRequest(
            actor: actor,
            title: title,
            context: context,
            severity: severity
          )
        )
      }
    )
  }

  @discardableResult
  public func assignTask(
    taskID: String,
    agentID: String,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Assign task"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.assignTask(sessionID: action.sessionID, taskID: taskID).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.assignTask(
          sessionID: action.sessionID,
          taskID: taskID,
          request: TaskAssignRequest(actor: actor, agentId: agentID)
        )
      }
    )
  }

  @discardableResult
  public func dropTask(
    taskID: String,
    target: TaskDropTarget,
    queuePolicy: TaskQueuePolicy = .locked,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Drop task"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.dropTask(sessionID: action.sessionID, taskID: taskID).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.dropTask(
          sessionID: action.sessionID,
          taskID: taskID,
          request: TaskDropRequest(
            actor: actor,
            target: target,
            queuePolicy: queuePolicy
          )
        )
      }
    )
  }

  @discardableResult
  public func updateTaskQueuePolicy(
    taskID: String,
    queuePolicy: TaskQueuePolicy,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Update task queue"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.updateTaskQueuePolicy(
        sessionID: action.sessionID,
        taskID: taskID
      ).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.updateTaskQueuePolicy(
          sessionID: action.sessionID,
          taskID: taskID,
          request: TaskQueuePolicyRequest(actor: actor, queuePolicy: queuePolicy)
        )
      }
    )
  }

  @discardableResult
  public func updateTaskStatus(
    taskID: String,
    status: TaskStatus,
    note: String? = nil,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Update task"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.updateTaskStatus(sessionID: action.sessionID, taskID: taskID)
        .key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.updateTask(
          sessionID: action.sessionID,
          taskID: taskID,
          request: TaskUpdateRequest(actor: actor, status: status, note: note)
        )
      }
    )
  }

  @discardableResult
  public func checkpointTask(
    taskID: String,
    summary: String,
    progress: Int,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Save checkpoint"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.checkpointTask(sessionID: action.sessionID, taskID: taskID).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.checkpointTask(
          sessionID: action.sessionID,
          taskID: taskID,
          request: TaskCheckpointRequest(
            actor: actor,
            summary: summary,
            progress: progress
          )
        )
      }
    )
  }
}
