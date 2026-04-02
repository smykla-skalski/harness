import Foundation

extension HarnessStore {
  private var readOnlySessionAccessMessage: String {
    """
    The harness daemon is offline. Persisted session data is available in
    read-only mode until live connection returns.
    """
  }

  func guardSessionActionsAvailable() -> Bool {
    guard !isSessionReadOnly else {
      lastError = readOnlySessionAccessMessage
      return false
    }
    return true
  }

  @discardableResult
  public func createTask(
    title: String,
    context: String?,
    severity: TaskSeverity,
    actor: String = "harness-app"
  ) async -> Bool {
    guard guardSessionActionsAvailable() else {
      return false
    }
    guard let client, let sessionID = selectedSessionID else {
      return false
    }
    guard let actor = actionActor(for: actor) else {
      return false
    }

    return await mutateSelectedSession(
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

  @discardableResult
  public func assignTask(
    taskID: String,
    agentID: String,
    actor: String = "harness-app"
  ) async -> Bool {
    guard guardSessionActionsAvailable() else {
      return false
    }
    guard let client, let sessionID = selectedSessionID else {
      return false
    }
    guard let actor = actionActor(for: actor) else {
      return false
    }

    return await mutateSelectedSession(
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

  @discardableResult
  public func updateTaskStatus(
    taskID: String,
    status: TaskStatus,
    note: String? = nil,
    actor: String = "harness-app"
  ) async -> Bool {
    guard guardSessionActionsAvailable() else {
      return false
    }
    guard let client, let sessionID = selectedSessionID else {
      return false
    }
    guard let actor = actionActor(for: actor) else {
      return false
    }

    return await mutateSelectedSession(
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

  @discardableResult
  public func checkpointTask(
    taskID: String,
    summary: String,
    progress: Int,
    actor: String = "harness-app"
  ) async -> Bool {
    guard guardSessionActionsAvailable() else {
      return false
    }
    guard let client, let sessionID = selectedSessionID else {
      return false
    }
    guard let actor = actionActor(for: actor) else {
      return false
    }

    return await mutateSelectedSession(
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

  @discardableResult
  public func changeRole(
    agentID: String,
    role: SessionRole,
    actor: String = "harness-app"
  ) async -> Bool {
    guard guardSessionActionsAvailable() else {
      return false
    }
    guard let client, let sessionID = selectedSessionID else {
      return false
    }
    guard let actor = actionActor(for: actor) else {
      return false
    }

    return await mutateSelectedSession(
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

  @discardableResult
  public func removeAgent(
    agentID: String,
    actor: String = "harness-app"
  ) async -> Bool {
    guard guardSessionActionsAvailable() else {
      return false
    }
    guard let client, let sessionID = selectedSessionID else {
      return false
    }
    guard let actor = actionActor(for: actor) else {
      return false
    }

    return await mutateSelectedSession(
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

  @discardableResult
  public func transferLeader(
    newLeaderID: String,
    reason: String? = nil,
    actor: String = "harness-app"
  ) async -> Bool {
    guard guardSessionActionsAvailable() else {
      return false
    }
    guard let client, let sessionID = selectedSessionID else {
      return false
    }
    guard let actor = actionActor(for: actor) else {
      return false
    }

    return await mutateSelectedSession(
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

  @discardableResult
  public func observeSelectedSession(actor: String = "harness-app") async -> Bool {
    guard guardSessionActionsAvailable() else {
      return false
    }
    guard let client, let sessionID = selectedSessionID else {
      return false
    }
    guard let actor = actionActor(for: actor) else {
      return false
    }

    return await mutateSelectedSession(
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

  @discardableResult
  public func endSelectedSession(actor: String = "harness-app") async -> Bool {
    guard guardSessionActionsAvailable() else {
      return false
    }
    guard let client, let sessionID = selectedSessionID else {
      return false
    }
    guard let actor = actionActor(for: actor) else {
      return false
    }

    return await mutateSelectedSession(
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
  }

  @discardableResult
  public func sendSignal(
    agentID: String,
    command: String,
    message: String,
    actionHint: String?,
    actor: String = "harness-app"
  ) async -> Bool {
    guard guardSessionActionsAvailable() else {
      return false
    }
    guard let client, let sessionID = selectedSessionID else {
      return false
    }
    guard let actor = actionActor(for: actor) else {
      return false
    }

    return await mutateSelectedSession(
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
    guard !isSessionReadOnly else {
      lastError = readOnlySessionAccessMessage
      return
    }
    guard let sessionID = selectedSessionID, let actorID = resolvedActionActor() else {
      return
    }
    pendingConfirmation = .endSession(sessionID: sessionID, actorID: actorID)
  }

  public func requestRemoveAgentConfirmation(agentID: String) {
    guard !isSessionReadOnly else {
      lastError = readOnlySessionAccessMessage
      return
    }
    guard let sessionID = selectedSessionID, let actorID = resolvedActionActor() else {
      return
    }
    pendingConfirmation = .removeAgent(sessionID: sessionID, agentID: agentID, actorID: actorID)
  }

  public func cancelConfirmation() {
    pendingConfirmation = nil
  }

  public func confirmPendingAction() async {
    guard !isSessionReadOnly else {
      pendingConfirmation = nil
      lastError = readOnlySessionAccessMessage
      return
    }
    guard let pendingConfirmation else {
      return
    }
    self.pendingConfirmation = nil

    switch pendingConfirmation {
    case .endSession(_, let actorID):
      await endSelectedSession(actor: actorID)
    case .removeAgent(_, let agentID, let actorID):
      await removeAgent(agentID: agentID, actor: actorID)
    }
  }

  func actionActor(for actor: String) -> String? {
    if actor != "harness-app" {
      return actor
    }
    return resolvedActionActor()
  }

  @discardableResult
  private func mutateSelectedSession(
    actionName: String,
    using client: any HarnessClientProtocol,
    sessionID: String,
    mutation: @escaping @Sendable () async throws -> SessionDetail
  ) async -> Bool {
    isSessionActionInFlight = true
    defer { isSessionActionInFlight = false }
    lastError = nil

    do {
      let measuredMutation = try await Self.measureOperation {
        try await mutation()
      }
      recordRequestSuccess()
      guard selectedSessionID == sessionID else {
        return true
      }
      selectedSession = measuredMutation.value
      applySessionSummaryUpdate(measuredMutation.value.session)
      synchronizeActionActor()
      scheduleSessionPushFallback(using: client, sessionID: sessionID)
      showLastAction(actionName)
      return true
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }
}
