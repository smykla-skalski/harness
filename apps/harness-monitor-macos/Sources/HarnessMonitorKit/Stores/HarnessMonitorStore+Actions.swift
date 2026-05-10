import Foundation

#if HARNESS_FEATURE_OTEL
  import OpenTelemetryApi
#endif

extension HarnessMonitorStore {
  public func reportDropRejection(_ reason: String) {
    presentFailureFeedback(reason)
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
  public func changeRole(
    sessionID: String,
    agentID: String,
    role: SessionRole,
    actorID: String
  ) async -> Bool {
    let actionName = "Change role"
    guard let action = prepareSessionAction(named: actionName, sessionID: sessionID) else {
      return false
    }
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: ActionID.changeRole(sessionID: sessionID, agentID: agentID).key,
      using: action.client,
      sessionID: sessionID,
      mutation: {
        try await action.client.changeRole(
          sessionID: sessionID,
          agentID: agentID,
          request: RoleChangeRequest(actor: actorID, role: role)
        )
      }
    )
  }

  @discardableResult
  public func observeSelectedSession(actor: String = "harness-app") async -> Bool {
    let actionName = "Observe session"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    let didObserve = await mutateSelectedSession(
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
    if didObserve {
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        await self.runSupervisorTickNow()
      }
    }
    return didObserve
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

  func endSession(
    sessionID: String,
    actorID: String
  ) async -> Bool {
    let actionName = "End session"
    guard let action = prepareSessionAction(named: actionName, sessionID: sessionID) else {
      return false
    }
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: ActionID.endSession(sessionID: sessionID).key,
      using: action.client,
      sessionID: sessionID,
      mutation: {
        try await action.client.endSession(
          sessionID: sessionID,
          request: SessionEndRequest(actor: actorID)
        )
      }
    )
  }

  func removeAgent(
    sessionID: String,
    agentID: String,
    actorID: String
  ) async -> Bool {
    let actionName = "Remove agent"
    guard let action = prepareSessionAction(named: actionName, sessionID: sessionID) else {
      return false
    }
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: ActionID.removeAgent(sessionID: sessionID, agentID: agentID).key,
      using: action.client,
      sessionID: sessionID,
      mutation: {
        try await action.client.removeAgent(
          sessionID: sessionID,
          agentID: agentID,
          request: AgentRemoveRequest(actor: actorID)
        )
      }
    )
  }

  public func requestRemoveAgentConfirmation(agentID: String) {
    requestRemoveAgentConfirmation(agentIDs: [agentID])
  }

  public func requestRemoveAgentConfirmation(agentIDs: [String]) {
    let normalized = orderedUniqueIDs(agentIDs)
    guard !normalized.isEmpty else { return }
    let actionName = "Remove agent"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return }
    guard guardLeaderActionsAvailable(actionName: actionName) else { return }
    guard let actorID = resolvedActionActorOrReport(actionName: actionName) else { return }
    if normalized.count == 1 {
      pendingConfirmation = .removeAgent(
        sessionID: action.sessionID,
        agentID: normalized[0],
        actorID: actorID
      )
    } else {
      pendingConfirmation = .removeAgents(
        sessionID: action.sessionID,
        agentIDs: normalized,
        actorID: actorID
      )
    }
  }

  public func requestRemoveAgentConfirmation(
    sessionID: String,
    agentID: String,
    actorID: String
  ) {
    requestRemoveAgentConfirmation(
      sessionID: sessionID,
      agentIDs: [agentID],
      actorID: actorID
    )
  }

  public func requestRemoveAgentConfirmation(
    sessionID: String,
    agentIDs: [String],
    actorID: String
  ) {
    let normalized = orderedUniqueIDs(agentIDs)
    guard !normalized.isEmpty else { return }
    if normalized.count == 1 {
      pendingConfirmation = .removeAgent(
        sessionID: sessionID,
        agentID: normalized[0],
        actorID: actorID
      )
    } else {
      pendingConfirmation = .removeAgents(
        sessionID: sessionID,
        agentIDs: normalized,
        actorID: actorID
      )
    }
  }

  /// Stop-on-first-failure policy: a structural failure (auth lapse, daemon
  /// gone, network down) usually means the next call also fails — better to
  /// surface where the boundary fell than hammer through 30 retries. The
  /// trade-off: a transient on item N strands items N+1…M even if they would
  /// individually succeed. The toast names the unattempted suffix so the user
  /// can re-select and retry.
  @discardableResult
  func removeAgents(
    sessionID: String,
    agentIDs: [String],
    actorID: String
  ) async -> Bool {
    guard !agentIDs.isEmpty else { return false }
    var succeeded = 0
    for (index, agentID) in agentIDs.enumerated() {
      let didRemove = await removeAgent(
        sessionID: sessionID,
        agentID: agentID,
        actorID: actorID
      )
      guard didRemove else {
        let remaining = agentIDs.count - index - 1
        presentFailureFeedback(
          "Removed \(succeeded) of \(agentIDs.count) agents. "
            + "Stopped after a failure with \(remaining) not attempted."
        )
        return false
      }
      succeeded += 1
    }
    if agentIDs.count > 1 {
      presentSuccessFeedback("Removed \(agentIDs.count) agents")
    }
    return true
  }

  public func requestRemoveSessionConfirmation(sessionID: String) {
    requestRemoveSessionConfirmation(sessionIDs: [sessionID], actor: "harness-app")
  }

  public func requestRemoveSessionConfirmation(sessionIDs: [String]) {
    requestRemoveSessionConfirmation(sessionIDs: sessionIDs, actor: "harness-app")
  }

  func requestRemoveSessionConfirmation(sessionID: String, actor: String) {
    requestRemoveSessionConfirmation(sessionIDs: [sessionID], actor: actor)
  }

  func requestRemoveSessionConfirmation(sessionIDs: [String], actor: String) {
    let normalizedSessionIDs = orderedUniqueSessionIDs(sessionIDs)
    let actionName = "Remove session"
    guard !normalizedSessionIDs.isEmpty else { return }
    guard
      normalizedSessionIDs.allSatisfy({
        prepareSessionAction(named: actionName, sessionID: $0) != nil
      })
    else { return }
    let actorID = controlPlaneActionActor(for: actor)
    if normalizedSessionIDs.count == 1 {
      pendingConfirmation = .removeSession(
        sessionID: normalizedSessionIDs[0],
        actorID: actorID
      )
    } else {
      pendingConfirmation = .removeSessions(
        sessionIDs: normalizedSessionIDs,
        actorID: actorID
      )
    }
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

  private func orderedUniqueSessionIDs(_ sessionIDs: [String]) -> [String] {
    orderedUniqueIDs(sessionIDs)
  }

  private func orderedUniqueIDs(_ ids: [String]) -> [String] {
    var seen: Set<String> = []
    return ids.filter { seen.insert($0).inserted }
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
          clearBurstState: false,
          showingCachedData: isShowingCachedData,
          cancelPendingTimelineRefresh: false
        )
        _ = sessionIndex.applySessionSummary(detail.session)
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
