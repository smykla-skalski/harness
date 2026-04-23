import Foundation

/// Stuck-agent detection rule. Phase 2 worker 7 implements the body per source plan Task 11:
/// trigger on `agent.idleSeconds > stuckThreshold` while the agent owns an in-progress task,
/// aggressively nudge up to N times, then queue a decision.
public struct StuckAgentRule: PolicyRule {
  public let id = "stuck-agent"
  public let name = "Stuck Agent"
  public let version = 1
  public let parameters = PolicyParameterSchema(fields: [
    .init(
      key: Self.thresholdKey,
      label: "Stuck threshold",
      kind: .duration,
      default: String(Self.defaultThresholdSeconds)
    ),
    .init(
      key: Self.maxRetriesKey,
      label: "Nudge retry limit",
      kind: .integer,
      default: String(Self.defaultMaxRetries)
    ),
    .init(
      key: Self.retryIntervalKey,
      label: "Nudge retry interval",
      kind: .duration,
      default: String(Self.defaultRetryIntervalSeconds)
    ),
  ])

  public static let thresholdKey = "stuckThreshold"
  public static let maxRetriesKey = "nudgeMaxRetries"
  public static let retryIntervalKey = "nudgeRetryInterval"

  public static let defaultThresholdSeconds = 120
  public static let defaultMaxRetries = 3
  public static let defaultRetryIntervalSeconds = 120

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
    let config = RuleConfig(
      thresholdSeconds: max(
        0,
        context.parameters.seconds(Self.thresholdKey, default: Self.defaultThresholdSeconds)
      ),
      maxRetries: max(
        0,
        context.parameters.int(Self.maxRetriesKey, default: Self.defaultMaxRetries)
      ),
      retryIntervalSeconds: max(
        0,
        context.parameters.seconds(
          Self.retryIntervalKey,
          default: Self.defaultRetryIntervalSeconds
        )
      )
    )

    return snapshot.sessions.compactMap { session in
      action(
        for: session,
        snapshot: snapshot,
        context: context,
        config: config
      )
    }
  }

  private func action(
    for session: SessionSnapshot,
    snapshot: SessionsSnapshot,
    context: PolicyContext,
    config: RuleConfig
  ) -> PolicyAction? {
    guard
      let match = firstMatchingAgent(in: session, thresholdSeconds: config.thresholdSeconds)
    else {
      return nil
    }

    let retries = retryState(for: match.agent.id, events: context.history.recentEvents)
    if retries.attemptCount >= config.maxRetries {
      let action = escalationDecision(
        match: match,
        sessionID: session.id,
        thresholdSeconds: config.thresholdSeconds,
        maxRetries: config.maxRetries
      )
      guard !context.recentActionKeys.contains(action.actionKey) else {
        return nil
      }
      return action
    }

    if let lastAttemptAt = retries.lastAttemptAt,
      context.now.timeIntervalSince(lastAttemptAt) < Double(config.retryIntervalSeconds)
    {
      return nil
    }

    let action = nudge(match: match, snapshot: snapshot)
    guard !context.recentActionKeys.contains(action.actionKey) else {
      return nil
    }
    return action
  }

  private func firstMatchingAgent(
    in session: SessionSnapshot,
    thresholdSeconds: Int
  ) -> MatchedAgentTask? {
    let tasksByID = Dictionary(uniqueKeysWithValues: session.tasks.map { ($0.id, $0) })
    return session.agents
      .sorted { $0.id < $1.id }
      .compactMap { agent -> MatchedAgentTask? in
        guard
          let taskID = agent.currentTaskID,
          let idleSeconds = agent.idleSeconds,
          idleSeconds > thresholdSeconds,
          let task = tasksByID[taskID],
          task.statusRaw == "in_progress"
        else {
          return nil
        }
        return MatchedAgentTask(agent: agent, task: task, idleSeconds: idleSeconds)
      }
      .first
  }

  private func retryState(
    for agentID: String,
    events: [SupervisorEventSummary]
  ) -> RetryState {
    let attempts =
      events
      .filter { $0.kind == "actionDispatched" && $0.ruleID == id }
      .filter { retryAgentID(from: $0.id) == agentID }
    return RetryState(
      attemptCount: attempts.count,
      lastAttemptAt: attempts.map(\.createdAt).max()
    )
  }

  private func retryAgentID(from actionKey: String) -> String? {
    let components = actionKey.split(separator: ":", omittingEmptySubsequences: false)
    guard components.count >= 4, components[0] == "nudge", components[1] == "stuck-agent" else {
      return nil
    }
    return String(components[2])
  }

  private func nudge(
    match: MatchedAgentTask,
    snapshot: SessionsSnapshot
  ) -> PolicyAction {
    .nudgeAgent(
      .init(
        agentID: match.agent.id,
        prompt: """
          You look stuck on task \(match.task.id). Post a brief progress update and ask for help \
          if you are blocked.
          """,
        ruleID: id,
        snapshotID: snapshot.id,
        snapshotHash: snapshot.hash
      )
    )
  }

  private func escalationDecision(
    match: MatchedAgentTask,
    sessionID: String,
    thresholdSeconds: Int,
    maxRetries: Int
  ) -> PolicyAction {
    .queueDecision(
      .init(
        id: "\(id):\(sessionID):\(match.agent.id):\(match.task.id)",
        severity: .needsUser,
        ruleID: id,
        sessionID: sessionID,
        agentID: match.agent.id,
        taskID: match.task.id,
        summary: "Agent \(match.agent.id) remains stuck on task \(match.task.id).",
        contextJSON: contextJSON(
          sessionID: sessionID,
          match: match,
          thresholdSeconds: thresholdSeconds,
          maxRetries: maxRetries
        ),
        suggestedActionsJSON: suggestedActionsJSON(for: match)
      )
    )
  }

  private func contextJSON(
    sessionID: String,
    match: MatchedAgentTask,
    thresholdSeconds: Int,
    maxRetries: Int
  ) -> String {
    let object: [String: Any] = [
      "agentID": match.agent.id,
      "idleSeconds": match.idleSeconds,
      "maxRetries": maxRetries,
      "sessionID": sessionID,
      "stuckThreshold": thresholdSeconds,
      "taskID": match.task.id,
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }

  private func suggestedActionsJSON(for match: MatchedAgentTask) -> String {
    let actions = [
      SuggestedAction(
        id: "nudge-\(match.agent.id)",
        title: "Nudge again",
        kind: .nudge,
        payloadJSON: encode(ActionPayload(mode: "nudgeAgain", agentID: match.agent.id))
      ),
      SuggestedAction(
        id: "investigate-\(match.agent.id)",
        title: "Investigate manually",
        kind: .custom,
        payloadJSON: encode(ActionPayload(mode: "investigate", agentID: match.agent.id))
      ),
      SuggestedAction(
        id: "dismiss-\(match.agent.id)",
        title: "Dismiss",
        kind: .dismiss,
        payloadJSON: "{}"
      ),
    ]
    return encode(actions)
  }

  private func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard
      let data = try? encoder.encode(value),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }
}

private struct MatchedAgentTask {
  let agent: AgentSnapshot
  let task: TaskSnapshot
  let idleSeconds: Int
}

private struct RetryState {
  let attemptCount: Int
  let lastAttemptAt: Date?
}

private struct RuleConfig {
  let thresholdSeconds: Int
  let maxRetries: Int
  let retryIntervalSeconds: Int
}

private struct ActionPayload: Encodable {
  let mode: String
  let agentID: String
}
