import Foundation

#if HARNESS_FEATURE_OTEL
  import OpenTelemetryApi
#endif

extension HarnessMonitorStore {
  var readOnlySessionAccessMessage: String {
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

  var noResolvedActionActorMessage: String {
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

  func reportUnavailableSelectedSessionAction(
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
      actionID: ActionID.changeRole(sessionID: action.sessionID, agentID: agentID).key,
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
      actionID: ActionID.removeAgent(sessionID: action.sessionID, agentID: agentID).key,
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
      actionID: ActionID.transferLeader(
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
      actionID: ActionID.observeSession(sessionID: action.sessionID).key,
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
      actionID: ActionID.endSession(sessionID: action.sessionID).key,
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
    #if HARNESS_FEATURE_OTEL
      let span = HarnessMonitorTelemetry.shared.startSpan(
        name: "user.action.\(interactionType)",
        kind: .internal,
        attributes: ["user.action.name": .string(actionName), "session.id": .string(sessionID)]
      )
    #endif

    isSessionActionInFlight = true
    inFlightActionID = actionID
    defer {
      isSessionActionInFlight = false
      if inFlightActionID == actionID {
        inFlightActionID = nil
      }
      #if HARNESS_FEATURE_OTEL
        span.end()
        let elapsed = startedAt.duration(to: ContinuousClock.now)
        let durationMs = harnessMonitorDurationMilliseconds(elapsed)
        HarnessMonitorTelemetry.shared.recordUserInteraction(
          interaction: interactionType,
          sessionID: sessionID,
          durationMs: durationMs
        )
      #else
        _ = startedAt
        _ = interactionType
      #endif
    }

    do {
      let body: () async throws -> Bool = { [self] in
        let measuredMutation = try await Self.measureOperation { try await mutation() }
        recordRequestSuccess()
        guard selectedSessionID == sessionID else {
          return true
        }
        let detail = sessionDetailPreservingFresherSelectedSummary(
          sessionID: sessionID,
          detail: measuredMutation.value
        )
        applySelectedSessionSnapshot(
          sessionID: sessionID,
          detail: detail,
          timeline: timeline,
          timelineWindow: timelineWindow,
          showingCachedData: isShowingCachedData,
          cancelPendingTimelineRefresh: false
        )
        scheduleSessionPushFallback(using: client, sessionID: sessionID)
        presentSuccessFeedback(actionName)
        return true
      }
      #if HARNESS_FEATURE_OTEL
        return try await HarnessMonitorTelemetryTaskContext.$parentSpanContext.withValue(
          span.context,
          operation: body
        )
      #else
        return try await body()
      #endif
    } catch {
      #if HARNESS_FEATURE_OTEL
        span.status = .error(description: error.localizedDescription)
        HarnessMonitorTelemetry.shared.recordError(error, on: span)
      #endif
      reportSelectedSessionActionFailure(actionName, sessionID: sessionID, error: error)
      presentSelectedSessionMutationFailure(error, actionID: actionID)
      return false
    }
  }

}
