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
    guard let actor = actionActor(for: actor) else {
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
    guard let actor = actionActor(for: actor) else {
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
    guard let actor = actionActor(for: actor) else {
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
    guard let actor = actionActor(for: actor) else {
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
    guard let actor = actionActor(for: actor) else {
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

  public func removeAgent(
    agentID: String,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }
    guard let actor = actionActor(for: actor) else {
      return
    }

    await mutateSelectedSession(
      actionName: "Remove agent",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.removeAgent(
          sessionID: sessionID,
          agentID: agentID,
          request: AgentRemoveRequest(actor: actor)
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
    guard let actor = actionActor(for: actor) else {
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

  public func observeSelectedSession(actor: String = "monitor-app") async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }
    guard let actor = actionActor(for: actor) else {
      return
    }

    await mutateSelectedSession(
      actionName: "Observe session",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.observeSession(
          sessionID: sessionID,
          request: ObserveSessionRequest(actor: actor)
        )
      }
    )
  }

  public func endSelectedSession(actor: String = "monitor-app") async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }
    guard let actor = actionActor(for: actor) else {
      return
    }

    await mutateSelectedSession(
      actionName: "End session",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.endSession(
          sessionID: sessionID,
          request: SessionEndRequest(actor: actor)
        )
      }
    )
    await refresh(using: client, preserveSelection: true)
  }

  public func sendSignal(
    agentID: String,
    command: String,
    message: String,
    actionHint: String?,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }
    guard let actor = actionActor(for: actor) else {
      return
    }

    await mutateSelectedSession(
      actionName: "Send signal",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.sendSignal(
          sessionID: sessionID,
          request: SignalSendRequest(
            actor: actor,
            agentId: agentID,
            command: command,
            message: message,
            actionHint: actionHint
          )
        )
      }
    )
  }

  public func requestEndSelectedSessionConfirmation() {
    guard let sessionID = selectedSessionID, let actorID = resolvedActionActor() else {
      return
    }
    pendingConfirmation = .endSession(sessionID: sessionID, actorID: actorID)
  }

  public func requestRemoveAgentConfirmation(agentID: String) {
    guard let sessionID = selectedSessionID, let actorID = resolvedActionActor() else {
      return
    }
    pendingConfirmation = .removeAgent(sessionID: sessionID, agentID: agentID, actorID: actorID)
  }

  public func requestRemoveLaunchAgentConfirmation() {
    pendingConfirmation = .removeLaunchAgent
  }

  public func cancelConfirmation() {
    pendingConfirmation = nil
  }

  public func confirmPendingAction() async {
    guard let pendingConfirmation else {
      return
    }
    self.pendingConfirmation = nil

    switch pendingConfirmation {
    case .endSession(_, let actorID):
      await endSelectedSession(actor: actorID)
    case .removeAgent(_, let agentID, let actorID):
      await removeAgent(agentID: agentID, actor: actorID)
    case .removeLaunchAgent:
      await removeLaunchAgent()
    }
  }

  func actionActor(for actor: String) -> String? {
    if actor != "monitor-app" {
      return actor
    }
    return resolvedActionActor()
  }

  private func mutateSelectedSession(
    actionName: String,
    using client: any MonitorClientProtocol,
    sessionID: String,
    mutation: () async throws -> SessionDetail
  ) async {
    isSessionActionInFlight = true
    defer { isSessionActionInFlight = false }
    lastError = nil

    do {
      selectedSession = try await mutation()
      let updatedTimeline = try await client.timeline(sessionID: sessionID)
      guard selectedSessionID == sessionID else {
        return
      }
      timeline = updatedTimeline
      await refresh(using: client, preserveSelection: true)
      lastAction = actionName
    } catch {
      lastError = error.localizedDescription
    }
  }
}
