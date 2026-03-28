import Foundation

extension MonitorStore {
  public func createTask(
    title: String,
    context: String?,
    severity: TaskSeverity,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      actionName: "Create task",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.createTask(
          sessionID: sessionID,
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

  public func assignTask(
    taskID: String,
    agentID: String,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      actionName: "Assign task",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.assignTask(
          sessionID: sessionID,
          taskID: taskID,
          request: TaskAssignRequest(actor: actor, agentId: agentID)
        )
      }
    )
  }

  public func updateTaskStatus(
    taskID: String,
    status: TaskStatus,
    note: String? = nil,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      actionName: "Update task",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.updateTask(
          sessionID: sessionID,
          taskID: taskID,
          request: TaskUpdateRequest(actor: actor, status: status, note: note)
        )
      }
    )
  }

  public func checkpointTask(
    taskID: String,
    summary: String,
    progress: Int,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      actionName: "Save checkpoint",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.checkpointTask(
          sessionID: sessionID,
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

  public func changeRole(
    agentID: String,
    role: SessionRole,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      actionName: "Change role",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.changeRole(
          sessionID: sessionID,
          agentID: agentID,
          request: RoleChangeRequest(actor: actor, role: role)
        )
      }
    )
  }

  public func transferLeader(
    newLeaderID: String,
    reason: String? = nil,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      actionName: "Transfer leader",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.transferLeader(
          sessionID: sessionID,
          request: LeaderTransferRequest(
            actor: actor,
            newLeaderId: newLeaderID,
            reason: reason
          )
        )
      }
    )
  }

  private func mutateSelectedSession(
    actionName: String,
    using client: any MonitorClientProtocol,
    sessionID: String,
    mutation: () async throws -> SessionDetail
  ) async {
    isBusy = true
    defer { isBusy = false }
    lastError = nil

    do {
      selectedSession = try await mutation()
      timeline = try await client.timeline(sessionID: sessionID)
      await refresh(using: client, preserveSelection: true)
      lastAction = actionName
    } catch {
      lastError = error.localizedDescription
    }
  }
}
