import Foundation

/// Idle-session rule. Emits a cautious `.queueDecision` when a session has a timeline-density of
/// zero in the last minute **and** every agent assigned to the session has been quiet for longer
/// than `sessionIdleThreshold` seconds (default 600s). The decision surfaces two suggested
/// actions — a check-in nudge and a session close — so the operator can move the session forward
/// without the supervisor acting autonomously.
///
/// Idempotency is delegated to `PolicyExecutor`: the emitted `.queueDecision` carries the stable
/// session id, so the executor's cool-down window dedupes repeat ticks until the decision
/// resolves or the session becomes active again.
public struct IdleSessionRule: PolicyRule {
  public let id = "idle-session"
  public let name = "Idle Session"
  public let version = 1
  public let parameters = PolicyParameterSchema(fields: [
    PolicyParameterSchema.Field(
      key: Self.thresholdKey,
      label: "Session idle threshold",
      kind: .duration,
      default: String(Self.defaultThresholdSeconds)
    )
  ])

  /// Parameter key for the idle-duration threshold, in seconds.
  public static let thresholdKey = "sessionIdleThreshold"
  /// Default idle threshold in seconds (10 minutes).
  public static let defaultThresholdSeconds = 600

  public init() {}

  public func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    _ = actionKey
    return .cautious
  }

  public func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    let threshold = context.parameters.seconds(
      Self.thresholdKey,
      default: Self.defaultThresholdSeconds
    )

    return snapshot.sessions.compactMap { session in
      evaluateSession(session, now: context.now, thresholdSeconds: threshold)
    }
  }

  // MARK: - Private

  private func evaluateSession(
    _ session: SessionSnapshot,
    now: Date,
    thresholdSeconds: Int
  ) -> PolicyAction? {
    guard session.timelineDensityLastMinute == 0, !session.agents.isEmpty else {
      return nil
    }
    guard isIdle(session: session, now: now, thresholdSeconds: thresholdSeconds) else {
      return nil
    }
    return .queueDecision(decisionPayload(for: session, idleSeconds: thresholdSeconds))
  }

  private func isIdle(session: SessionSnapshot, now: Date, thresholdSeconds: Int) -> Bool {
    let mostRecent = session.agents.compactMap(\.lastActivityAt).max()
    guard let mostRecent else {
      // No agent has ever recorded activity — treat as infinitely idle.
      return true
    }
    let idleSeconds = now.timeIntervalSince(mostRecent)
    return idleSeconds > Double(thresholdSeconds)
  }

  private func decisionPayload(
    for session: SessionSnapshot,
    idleSeconds: Int
  ) -> PolicyAction.DecisionPayload {
    let summary = "Session \(session.id) has had no activity for over \(idleSeconds)s."
    return PolicyAction.DecisionPayload(
      id: session.id,
      severity: .warn,
      ruleID: id,
      sessionID: session.id,
      agentID: nil,
      taskID: nil,
      summary: summary,
      contextJSON: contextJSON(sessionID: session.id, thresholdSeconds: idleSeconds),
      suggestedActionsJSON: Self.suggestedActionsJSON
    )
  }

  private func contextJSON(sessionID: String, thresholdSeconds: Int) -> String {
    let object: [String: Any] = [
      "sessionID": sessionID,
      "ruleID": id,
      "sessionIdleThreshold": thresholdSeconds,
    ]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
      ),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }

  private static let suggestedActionsJSON: String = {
    let actions = [
      SuggestedAction(
        id: "idle-session.nudge",
        title: "Send check-in nudge",
        kind: .nudge,
        payloadJSON: "{}"
      ),
      SuggestedAction(
        id: "idle-session.close",
        title: "Close session",
        kind: .custom,
        payloadJSON: "{}"
      ),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard
      let data = try? encoder.encode(actions),
      let string = String(data: data, encoding: .utf8)
    else {
      return "[]"
    }
    return string
  }()
}
