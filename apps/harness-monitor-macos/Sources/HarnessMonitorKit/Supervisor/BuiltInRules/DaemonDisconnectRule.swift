import Foundation

/// Daemon-disconnect rule. Source plan Task 15. Triggers when the Monitor's connection to the
/// daemon has been `disconnected` for longer than `disconnectGraceSeconds`. Aggressive default:
/// emit `.notifyOnly` so the existing reconnect chain keeps running. Once the disconnect has
/// lasted longer than `disconnectEscalationSeconds`, escalate to a `.queueDecision` with
/// `.critical` severity so the user can intervene.
///
/// Duplicate suppression uses `PolicyContext.recentActionKeys`. The decision id is stable per
/// disconnect episode (anchored to `connection.lastMessageAt` when present, otherwise to
/// `snapshot.createdAt`) so tick N+1 produces the same `actionKey` and the executor dedupes it.
public struct DaemonDisconnectRule: PolicyRule {
  public let id = "daemon-disconnect"
  public let name = "Daemon Disconnect"
  public let version = 1
  public let parameters = PolicyParameterSchema(fields: [
    PolicyParameterSchema.Field(
      key: Self.graceKey,
      label: "Grace period (seconds)",
      kind: .duration,
      default: String(Self.defaultGraceSeconds)
    ),
    PolicyParameterSchema.Field(
      key: Self.escalationKey,
      label: "Escalation threshold (seconds)",
      kind: .duration,
      default: String(Self.defaultEscalationSeconds)
    ),
  ])

  static let graceKey = "disconnectGraceSeconds"
  static let escalationKey = "disconnectEscalationSeconds"
  static let defaultGraceSeconds = 15
  static let defaultEscalationSeconds = 60

  public init() {}

  public func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    if actionKey.hasPrefix("decision:") {
      return .cautious
    }
    return .aggressive
  }

  public func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    guard snapshot.connection.kind == "disconnected" else { return [] }

    let grace = max(0, context.parameters.seconds(Self.graceKey, default: Self.defaultGraceSeconds))
    let escalation = max(
      grace,
      context.parameters.seconds(Self.escalationKey, default: Self.defaultEscalationSeconds)
    )

    let anchor = snapshot.connection.lastMessageAt ?? snapshot.createdAt
    let elapsed = context.now.timeIntervalSince(anchor)

    if elapsed <= Double(grace) {
      return []
    }

    if elapsed > Double(escalation) {
      guard let action = escalationDecision(snapshot: snapshot, anchor: anchor, context: context)
      else {
        return []
      }
      return [action]
    }

    guard let action = notify(snapshot: snapshot, elapsed: elapsed, context: context) else {
      return []
    }
    return [action]
  }

  // MARK: - Action builders

  private func notify(
    snapshot: SessionsSnapshot,
    elapsed: TimeInterval,
    context: PolicyContext
  ) -> PolicyAction? {
    let seconds = Int(elapsed.rounded())
    let summary = "Daemon disconnected for \(seconds)s — waiting for reconnect"
    let payload = PolicyAction.NotifyPayload(
      ruleID: id,
      snapshotID: snapshot.id,
      snapshotHash: snapshot.hash,
      severity: .warn,
      summary: summary
    )
    let action = PolicyAction.notifyOnly(payload)
    guard !context.recentActionKeys.contains(action.actionKey) else {
      return nil
    }
    return action
  }

  private func escalationDecision(
    snapshot: SessionsSnapshot,
    anchor: Date,
    context: PolicyContext
  ) -> PolicyAction? {
    let decisionID = "daemon-disconnect:\(Int(anchor.timeIntervalSince1970))"
    let elapsedSeconds = Int(context.now.timeIntervalSince(anchor).rounded())
    let summary = "Daemon has been disconnected for over \(elapsedSeconds)s"
    let payload = PolicyAction.DecisionPayload(
      id: decisionID,
      severity: .critical,
      ruleID: id,
      sessionID: nil,
      agentID: nil,
      taskID: nil,
      summary: summary,
      contextJSON: contextJSON(snapshot: snapshot, anchor: anchor),
      suggestedActionsJSON: suggestedActionsJSON
    )
    let action = PolicyAction.queueDecision(payload)
    guard !context.recentActionKeys.contains(action.actionKey) else {
      return nil
    }
    return action
  }

  private func contextJSON(snapshot: SessionsSnapshot, anchor: Date) -> String {
    let payload: [String: Any] = [
      "connectionKind": snapshot.connection.kind,
      "reconnectAttempt": snapshot.connection.reconnectAttempt,
      "disconnectedSince": anchor.timeIntervalSince1970,
      "snapshotID": snapshot.id,
    ]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
      ),
      let json = String(data: data, encoding: .utf8)
    else {
      HarnessMonitorLogger.supervisor.error(
        "daemon-disconnect failed to encode context JSON"
      )
      return "{}"
    }
    return json
  }

  private var suggestedActionsJSON: String {
    encode([
      SuggestedAction(
        id: "restart-daemon",
        title: "Restart daemon",
        kind: .custom,
        payloadJSON: "{\"mode\":\"restartDaemon\"}"
      ),
      SuggestedAction(
        id: "open-daemon-logs",
        title: "Open daemon logs",
        kind: .custom,
        payloadJSON: "{\"mode\":\"openDaemonLogs\"}"
      ),
      SuggestedAction(
        id: "dismiss",
        title: "Dismiss",
        kind: .dismiss,
        payloadJSON: "{}"
      ),
    ])
  }

  private func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard
      let data = try? encoder.encode(value),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }
}
