import Foundation
import OpenTelemetryApi

extension HarnessMonitorStore {
  private var readOnlySessionAccessMessage: String {
    """
    The harness daemon is offline. Persisted session data is available in
    read-only mode until live connection returns.
    """
  }

  private var actionChannelUnavailableMessage: String {
    "The daemon action channel is unavailable. Refresh the session and try again."
  }

  private var noSelectedSessionActionMessage: String {
    "No session is selected. Choose a session and try again."
  }

  private var noResolvedActionActorMessage: String {
    "No session actor is available yet. Wait for a leader or active agent to join, then try again."
  }

  private var noSelectedLeaderMessage: String {
    """
    Leader-only actions are unavailable until a real leader joins this session.
    Observe, end session, and task controls remain available.
    """
  }

  public var selectedSessionActionUnavailableMessage: String? {
    if isSessionReadOnly {
      return readOnlySessionAccessMessage
    }
    if selectedSessionID == nil {
      return noSelectedSessionActionMessage
    }
    if client == nil {
      return actionChannelUnavailableMessage
    }
    return nil
  }

  public var areSelectedSessionActionsAvailable: Bool {
    selectedSessionActionUnavailableMessage == nil
  }

  public var selectedLeaderActionUnavailableMessage: String? {
    if let generalUnavailableMessage = selectedSessionActionUnavailableMessage {
      return generalUnavailableMessage
    }
    guard selectedSessionHasRealLeader else {
      return noSelectedLeaderMessage
    }
    if resolvedActionActor() == nil {
      return noResolvedActionActorMessage
    }
    return nil
  }

  public var areSelectedLeaderActionsAvailable: Bool {
    selectedLeaderActionUnavailableMessage == nil
  }

  public var selectedSessionActionBannerMessage: String? {
    selectedLeaderActionUnavailableMessage ?? selectedSessionActionUnavailableMessage
  }

  func guardSessionActionsAvailable(actionName: String = "Session action") -> Bool {
    guard let unavailableMessage = selectedSessionActionUnavailableMessage else {
      return true
    }
    reportUnavailableSelectedSessionAction(actionName, message: unavailableMessage)
    return false
  }

  func guardLeaderActionsAvailable(actionName: String = "Session action") -> Bool {
    guard let unavailableMessage = selectedLeaderActionUnavailableMessage else {
      return true
    }
    reportUnavailableSelectedSessionAction(actionName, message: unavailableMessage)
    return false
  }

  private func reportUnavailableSelectedSessionAction(
    _ actionName: String,
    message: String
  ) {
    let sessionID = selectedSessionID ?? "none"
    let leaderID = selectedSession?.session.leaderId ?? "none"
    let actorID = actionActorID ?? "none"
    let activeActors = availableActionActors.map(\.agentId).joined(separator: ",")
    HarnessMonitorLogger.store.warning(
      """
      Session action unavailable: \(actionName, privacy: .public); reason=\
      \(message, privacy: .public); sessionID=\(sessionID, privacy: .public); \
      leaderID=\(leaderID, privacy: .public); actorID=\(actorID, privacy: .public); \
      activeActors=\(activeActors, privacy: .public)
      """
    )
    presentFailureFeedback(message)
  }

  private func reportSelectedSessionActionFailure(
    _ actionName: String,
    sessionID: String,
    error: any Error
  ) {
    HarnessMonitorLogger.store.error(
      """
      Session action failed: \(actionName, privacy: .public); \
      sessionID=\(sessionID, privacy: .public); \
      error=\(error.localizedDescription, privacy: .public)
      """
    )
  }

  func prepareSelectedSessionAction(
    named actionName: String
  ) -> (client: any HarnessMonitorClientProtocol, sessionID: String)? {
    if isSessionReadOnly {
      reportUnavailableSelectedSessionAction(actionName, message: readOnlySessionAccessMessage)
      return nil
    }
    guard let sessionID = selectedSessionID else {
      reportUnavailableSelectedSessionAction(actionName, message: noSelectedSessionActionMessage)
      return nil
    }
    guard let client else {
      reportUnavailableSelectedSessionAction(actionName, message: actionChannelUnavailableMessage)
      return nil
    }
    return (client, sessionID)
  }

  public func reportDropRejection(_ reason: String) {
    presentFailureFeedback(reason)
  }

  private var selectedSessionHasRealLeader: Bool {
    guard let detail = selectedSession else {
      return false
    }
    guard let leaderID = detail.session.leaderId else {
      return false
    }
    return detail.agents.contains { $0.agentId == leaderID }
  }

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

  @discardableResult
  public func changeRole(
    agentID: String,
    role: SessionRole,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Change role"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    guard let actor = leaderActionActor(for: actor, actionName: actionName) else { return false }
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.changeRole(sessionID: action.sessionID, agentID: agentID).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.changeRole(
          sessionID: action.sessionID,
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
    let actionName = "Remove agent"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    guard let actor = leaderActionActor(for: actor, actionName: actionName) else { return false }
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.removeAgent(sessionID: action.sessionID, agentID: agentID).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.removeAgent(
          sessionID: action.sessionID,
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
    let actionName = "Transfer leader"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    guard let actor = leaderActionActor(for: actor, actionName: actionName) else { return false }
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.transferLeader(
        sessionID: action.sessionID,
        newLeaderID: newLeaderID
      ).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.transferLeader(
          sessionID: action.sessionID,
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
    let actionName = "Observe session"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.observeSession(sessionID: action.sessionID).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.observeSession(
          sessionID: action.sessionID,
          request: ObserveSessionRequest(actor: actor)
        )
      }
    )
  }

  @discardableResult
  public func endSelectedSession(actor: String = "harness-app") async -> Bool {
    let actionName = "End session"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.endSession(sessionID: action.sessionID).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.endSession(
          sessionID: action.sessionID,
          request: SessionEndRequest(actor: actor)
        )
      }
    )
  }

  public func requestEndSelectedSessionConfirmation() {
    requestEndSelectedSessionConfirmation(actor: "harness-app")
  }

  func requestEndSelectedSessionConfirmation(actor: String) {
    let actionName = "End session"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return }
    let actorID = controlPlaneActionActor(for: actor)
    pendingConfirmation = .endSession(sessionID: action.sessionID, actorID: actorID)
  }

  public func requestRemoveAgentConfirmation(agentID: String) {
    let actionName = "Remove agent"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return }
    guard guardLeaderActionsAvailable(actionName: actionName) else { return }
    guard let actorID = resolvedActionActorOrReport(actionName: actionName) else { return }
    pendingConfirmation = .removeAgent(
      sessionID: action.sessionID,
      agentID: agentID,
      actorID: actorID
    )
  }

  public func setDaemonLogLevel(_ level: String) async {
    let previousLevel = daemonLogLevel
    daemonLogLevel = level
    guard let client else {
      daemonLogLevel = previousLevel
      return
    }
    do {
      let response = try await client.setLogLevel(level)
      daemonLogLevel = response.level
    } catch {
      daemonLogLevel = previousLevel
      presentFailureFeedback(error.localizedDescription)
    }
  }

  public func cancelConfirmation() {
    pendingConfirmation = nil
  }

  public func confirmPendingAction() async {
    guard !isSessionReadOnly else {
      pendingConfirmation = nil
      reportUnavailableSelectedSessionAction("Confirm pending action", message: readOnlySessionAccessMessage)
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

  func actionActor(for actor: String, actionName: String = "Session action") -> String? {
    if actor != "harness-app" {
      return actor
    }
    return resolvedActionActorOrReport(actionName: actionName)
  }

  func controlPlaneActionActor(for actor: String) -> String {
    actor == "harness-app" ? "harness-app" : actor
  }

  func leaderActionActor(
    for actor: String,
    actionName: String = "Session action"
  ) -> String? {
    guard guardLeaderActionsAvailable(actionName: actionName) else {
      return nil
    }
    return actionActor(for: actor, actionName: actionName)
  }

  private func resolvedActionActorOrReport(actionName: String) -> String? {
    guard let actorID = resolvedActionActor() else {
      reportUnavailableSelectedSessionAction(actionName, message: noResolvedActionActorMessage)
      return nil
    }
    return actorID
  }

  @discardableResult
  func mutateSelectedSession(
    actionName: String,
    actionID: String,
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    mutation: @escaping @Sendable () async throws -> SessionDetail
  ) async -> Bool {
    let startedAt = ContinuousClock.now
    let interactionType = actionName.lowercased().replacingOccurrences(of: " ", with: "_")
    let span = HarnessMonitorTelemetry.shared.startSpan(
      name: "user.action.\(interactionType)",
      kind: .internal,
      attributes: ["user.action.name": .string(actionName), "session.id": .string(sessionID)]
    )

    isSessionActionInFlight = true
    inFlightActionID = actionID
    defer {
      isSessionActionInFlight = false
      if inFlightActionID == actionID {
        inFlightActionID = nil
      }
      span.end()
      let elapsed = startedAt.duration(to: ContinuousClock.now)
      let durationMs = harnessMonitorDurationMilliseconds(elapsed)
      HarnessMonitorTelemetry.shared.recordUserInteraction(
        interaction: interactionType,
        sessionID: sessionID,
        durationMs: durationMs
      )
    }

    do {
      return try await HarnessMonitorTelemetryTaskContext.$parentSpanContext.withValue(span.context)
      {
        let measuredMutation = try await Self.measureOperation { try await mutation() }
        recordRequestSuccess()
        guard selectedSessionID == sessionID else {
          return true
        }
        selectedSession = measuredMutation.value
        applySessionSummaryUpdate(measuredMutation.value.session)
        synchronizeActionActor()
        scheduleSessionPushFallback(using: client, sessionID: sessionID)
        presentSuccessFeedback(actionName)
        return true
      }
    } catch {
      span.status = .error(description: error.localizedDescription)
      HarnessMonitorTelemetry.shared.recordError(error, on: span)
      reportSelectedSessionActionFailure(actionName, sessionID: sessionID, error: error)
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}
