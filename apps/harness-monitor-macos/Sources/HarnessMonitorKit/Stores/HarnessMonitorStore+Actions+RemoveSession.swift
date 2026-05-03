import Foundation

#if HARNESS_FEATURE_OTEL
  import OpenTelemetryApi
#endif

extension HarnessMonitorStore {
  func reportSelectedSessionActionFailure(
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

  @discardableResult
  func removeSession(
    sessionID: String,
    actorID: String
  ) async -> Bool {
    let actionName = "Remove session"
    guard let action = prepareSessionAction(named: actionName, sessionID: sessionID) else {
      return false
    }
    let actionID = ActionID.removeSession(sessionID: sessionID).key
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
      HarnessMonitorLogger.store.info(
        """
        Remove session started; \
        sessionID=\(sessionID, privacy: .public); \
        selectedSessionID=\(self.selectedSessionID ?? "nil", privacy: .public); \
        visibleSessionCount=\(self.visibleSessionIDs.count, privacy: .public)
        """
      )
      HarnessMonitorUITestTrace.record(
        component: "store.remove-session",
        event: "started",
        details: [
          "session_id": sessionID,
          "selected_session_id": selectedSessionID ?? "nil",
        ]
      )
      return try await archiveAndFinalizeRemovedSession(
        sessionID: sessionID,
        actorID: actorID,
        actionName: actionName,
        client: action.client
      )
    } catch {
      #if HARNESS_FEATURE_OTEL
        span.status = .error(description: error.localizedDescription)
        HarnessMonitorTelemetry.shared.recordError(error, on: span)
      #endif
      return await handleRemoveSessionFailure(
        error,
        sessionID: sessionID,
        actionName: actionName,
        actionID: actionID,
        client: action.client
      )
    }
  }

  private func archiveAndFinalizeRemovedSession(
    sessionID: String,
    actorID: String,
    actionName: String,
    client: any HarnessMonitorClientProtocol
  ) async throws -> Bool {
    let measuredArchive = try await Self.measureOperation {
      try await client.archiveSession(
        sessionID: sessionID,
        request: SessionArchiveRequest(actor: actorID)
      )
    }
    _ = measuredArchive
    recordRequestSuccess()
    HarnessMonitorLogger.store.info(
      "Remove session archive succeeded; sessionID=\(sessionID, privacy: .public)"
    )
    HarnessMonitorUITestTrace.record(
      component: "store.remove-session",
      event: "archive-succeeded",
      details: ["session_id": sessionID]
    )
    return await finalizeLocalSessionRemoval(
      sessionID: sessionID,
      actionName: actionName,
      client: client
    )
  }

  private func handleRemoveSessionFailure(
    _ error: any Error,
    sessionID: String,
    actionName: String,
    actionID: String,
    client: any HarnessMonitorClientProtocol
  ) async -> Bool {
    if shouldTreatMissingRemoveSessionArchiveAsLocalSuccess(error) {
      recordRequestSuccess()
      HarnessMonitorLogger.store.info(
        """
        Remove session falling back to local success after daemon missing-session reply; \
        sessionID=\(sessionID, privacy: .public); \
        serverMessage=\(self.removeSessionServerMessage(from: error), privacy: .public); \
        serverSemanticCode=\(self.removeSessionServerSemanticCode(from: error), privacy: .public)
        """
      )
      HarnessMonitorUITestTrace.record(
        component: "store.remove-session",
        event: "archive-missing-treated-as-success",
        details: [
          "session_id": sessionID,
          "error": String(describing: error),
        ]
      )
      return await finalizeLocalSessionRemoval(
        sessionID: sessionID,
        actionName: actionName,
        client: client
      )
    }

    HarnessMonitorUITestTrace.record(
      component: "store.remove-session",
      event: "failed",
      details: [
        "session_id": sessionID,
        "error": String(describing: error),
      ]
    )
    HarnessMonitorLogger.store.error(
      """
      Remove session failed; \
      sessionID=\(sessionID, privacy: .public); \
      serverMessage=\(self.removeSessionServerMessage(from: error), privacy: .public); \
      serverSemanticCode=\(self.removeSessionServerSemanticCode(from: error), privacy: .public); \
      error=\(error.localizedDescription, privacy: .public)
      """
    )
    reportSelectedSessionActionFailure(actionName, sessionID: sessionID, error: error)
    presentSelectedSessionMutationFailure(error, actionID: actionID)
    return false
  }

  private func finalizeLocalSessionRemoval(
    sessionID: String,
    actionName: String,
    client: any HarnessMonitorClientProtocol
  ) async -> Bool {
    let localSnapshot = applyLocalSessionRemoval(sessionID: sessionID)
    HarnessMonitorUITestTrace.record(
      component: "store.remove-session",
      event: "local-removal-applied",
      details: [
        "session_id": sessionID,
        "remaining_session_count": String(localSnapshot.sessions.count),
        "remaining_project_count": String(localSnapshot.projects.count),
        "selected_session_id": selectedSessionID ?? "nil",
      ]
    )
    HarnessMonitorLogger.store.info(
      """
      Remove session local removal applied; \
      sessionID=\(sessionID, privacy: .public); \
      remainingSessionCount=\(localSnapshot.sessions.count, privacy: .public); \
      remainingProjectCount=\(localSnapshot.projects.count, privacy: .public)
      """
    )
    await pruneRemovedSessionFromCache(
      sessions: localSnapshot.sessions,
      projects: localSnapshot.projects
    )
    presentSuccessFeedback(actionName)
    await refresh(
      using: client,
      preserveSelection: true,
      allowPreviewReadySelection: false
    )
    HarnessMonitorUITestTrace.record(
      component: "store.remove-session",
      event: "refresh-finished",
      details: [
        "session_id": sessionID,
        "selected_session_id": selectedSessionID ?? "nil",
        "visible_session_count": String(visibleSessionIDs.count),
      ]
    )
    HarnessMonitorLogger.store.info(
      """
      Remove session refresh finished; \
      sessionID=\(sessionID, privacy: .public); \
      selectedSessionID=\(self.selectedSessionID ?? "nil", privacy: .public); \
      visibleSessionCount=\(self.visibleSessionIDs.count, privacy: .public)
      """
    )
    return true
  }

  private func shouldTreatMissingRemoveSessionArchiveAsLocalSuccess(
    _ error: any Error
  ) -> Bool {
    guard let apiError = error as? HarnessMonitorAPIError else {
      return false
    }
    guard case .server(let code, _) = apiError, (400...404).contains(code) else {
      return false
    }

    if apiError.serverSemanticCode?.lowercased() == "session_not_active" {
      return removeSessionServerMessage(from: error).localizedCaseInsensitiveContains("not found")
    }

    let message = removeSessionServerMessage(from: error).lowercased()
    return message.contains("session not active")
      && message.contains("session")
      && message.contains("not found")
  }

  private func removeSessionServerMessage(from error: any Error) -> String {
    guard let apiError = error as? HarnessMonitorAPIError else {
      return error.localizedDescription
    }
    return apiError.serverMessage ?? error.localizedDescription
  }

  private func removeSessionServerSemanticCode(from error: any Error) -> String {
    guard let apiError = error as? HarnessMonitorAPIError else {
      return "nil"
    }
    return apiError.serverSemanticCode ?? "nil"
  }
}
