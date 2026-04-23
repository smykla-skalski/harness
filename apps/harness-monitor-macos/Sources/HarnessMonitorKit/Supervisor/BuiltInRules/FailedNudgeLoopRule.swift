import Foundation

/// Failed-nudge escalation rule. Phase 2 worker 12 implements per source plan Task 16: trigger
/// on 3 consecutive `.actionFailed` events for the same agent emitted by `StuckAgentRule`;
/// always queues a decision because this rule is itself the escalation path.
public struct FailedNudgeLoopRule: PolicyRule {
  public let id = "failed-nudge-loop"
  public let name = "Failed Nudge Loop"
  public let version = 1
  public let parameters = PolicyParameterSchema(fields: [
    .init(
      key: "consecutiveFailureThreshold",
      label: "Consecutive failure threshold",
      kind: .integer,
      default: "3"
    )
  ])

  public init() {}

  public func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    _ = actionKey
    return .cautious
  }

  public func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    let threshold = context.parameters.int("consecutiveFailureThreshold", default: 3)
    return streaks(from: context.history.recentEvents)
      .filter { $0.count >= threshold }
      .compactMap { streak in
        action(for: streak, snapshotID: snapshot.id, context: context)
      }
  }

  private func streaks(from events: [SupervisorEventSummary]) -> [FailureStreak] {
    var streaks: [String: FailureStreak] = [:]

    for event in events.sorted(by: { $0.createdAt < $1.createdAt }) {
      guard event.ruleID == "stuck-agent", let agentID = agentID(from: event.id) else {
        continue
      }
      if event.kind == "actionFailed" {
        let nextCount = (streaks[agentID]?.count ?? 0) + 1
        streaks[agentID] = FailureStreak(
          agentID: agentID,
          count: nextCount,
          latestAt: event.createdAt
        )
      } else {
        streaks[agentID] = FailureStreak(
          agentID: agentID,
          count: 0,
          latestAt: event.createdAt
        )
      }
    }

    return streaks.values.sorted { left, right in
      if left.latestAt != right.latestAt {
        return left.latestAt < right.latestAt
      }
      return left.agentID < right.agentID
    }
  }

  private func agentID(from actionKey: String) -> String? {
    let components = actionKey.split(separator: ":", omittingEmptySubsequences: false)
    guard components.count >= 4, components[0] == "nudge", components[1] == "stuck-agent" else {
      return nil
    }
    return String(components[2])
  }

  private func action(
    for streak: FailureStreak,
    snapshotID: String,
    context: PolicyContext
  ) -> PolicyAction? {
    let payload = PolicyAction.DecisionPayload(
      id: "\(id):\(streak.agentID)",
      severity: .needsUser,
      ruleID: id,
      sessionID: nil,
      agentID: streak.agentID,
      taskID: nil,
      summary: """
        Supervisor could not recover agent \(streak.agentID) after repeated nudge failures.
        """,
      contextJSON: encode(ContextPayload(snapshotID: snapshotID, streak: streak)),
      suggestedActionsJSON: encode(suggestedActions(for: streak.agentID))
    )
    let action = PolicyAction.queueDecision(payload)
    guard !context.recentActionKeys.contains(action.actionKey) else {
      return nil
    }
    return action
  }

  private func suggestedActions(for agentID: String) -> [SuggestedAction] {
    [
      .init(
        id: "restart-agent",
        title: "Restart agent",
        kind: .custom,
        payloadJSON: encode(ActionPayload(mode: "restartAgent", agentID: agentID))
      ),
      .init(
        id: "stop-nudging-agent",
        title: "Stop nudging this agent",
        kind: .custom,
        payloadJSON: encode(ActionPayload(mode: "stopNudgingAgent", agentID: agentID))
      ),
      .init(
        id: "investigate-agent",
        title: "Investigate manually",
        kind: .custom,
        payloadJSON: encode(ActionPayload(mode: "investigateManually", agentID: agentID))
      ),
    ]
  }

  private func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard
      let data = try? encoder.encode(value),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }
}

private struct FailureStreak {
  let agentID: String
  let count: Int
  let latestAt: Date
}

private struct ContextPayload: Encodable {
  let snapshotID: String
  let agentID: String
  let consecutiveFailures: Int
  let latestFailureAt: Date

  init(snapshotID: String, streak: FailureStreak) {
    self.snapshotID = snapshotID
    agentID = streak.agentID
    consecutiveFailures = streak.count
    latestFailureAt = streak.latestAt
  }
}

private struct ActionPayload: Encodable {
  let mode: String
  let agentID: String
}
