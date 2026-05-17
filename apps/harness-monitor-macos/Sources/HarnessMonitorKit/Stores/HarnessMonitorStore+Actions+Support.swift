import Foundation

#if HARNESS_FEATURE_OTEL
  import OpenTelemetryApi
#endif

extension HarnessMonitorStore {
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

  func orderedUniqueSessionIDs(_ sessionIDs: [String]) -> [String] {
    orderedUniqueIDs(sessionIDs)
  }

  func orderedUniqueIDs(_ ids: [String]) -> [String] {
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

  func resolvedActionActorOrReport(actionName: String) -> String? {
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
        let detail = sessionDetailPreservingFresherSelectedSummary(
          sessionID: sessionID,
          detail: measuredMutation.value
        )
        applySessionSummaryUpdate(detail.session)
        guard selectedSessionID == sessionID else {
          presentSuccessFeedback(actionName)
          return true
        }
        applySelectedSessionSnapshot(
          sessionID: sessionID,
          detail: detail,
          timeline: timeline,
          timelineWindow: timelineWindow,
          clearBurstState: false,
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
