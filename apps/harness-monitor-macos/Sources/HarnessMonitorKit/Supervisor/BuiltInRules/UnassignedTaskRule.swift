import Foundation

/// Unassigned-task rule. Phase 2 worker 8 implements the body per source plan Task 12: trigger
/// when the session has tasks in `open` while ≥ 1 agent is `active`; cautious default queues a
/// decision with suggested "Assign to {agentID}" actions.
public struct UnassignedTaskRule: PolicyRule {
  public let id = "unassigned-task"
  public let name = "Unassigned Task"
  public let version = 1
  public let parameters = PolicyParameterSchema(fields: [
    .init(
      key: Self.thresholdKey,
      label: "Unassigned threshold",
      kind: .duration,
      default: String(Self.defaultThresholdSeconds)
    )
  ])

  public static let thresholdKey = "unassignedThreshold"
  public static let defaultThresholdSeconds = 120

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
    return snapshot.sessions.flatMap { session in
      actions(for: session, snapshot: snapshot, context: context, thresholdSeconds: threshold)
    }
  }

  private func actions(
    for session: SessionSnapshot,
    snapshot: SessionsSnapshot,
    context: PolicyContext,
    thresholdSeconds: Int
  ) -> [PolicyAction] {
    let activeAgents = session.agents
      .filter { $0.statusRaw == "active" }
      .sorted { $0.id < $1.id }
    guard !activeAgents.isEmpty else { return [] }
    let input = ActionInput(
      activeAgents: activeAgents,
      snapshotID: snapshot.id,
      thresholdSeconds: thresholdSeconds
    )

    return session.tasks.compactMap { task in
      action(for: task, sessionID: session.id, context: context, input: input)
    }
  }

  private func action(
    for task: TaskSnapshot,
    sessionID: String,
    context: PolicyContext,
    input: ActionInput
  ) -> PolicyAction? {
    guard task.statusRaw == "open", task.assignedAgentID == nil else { return nil }
    let ageSeconds = context.now.timeIntervalSince(task.createdAt)
    guard ageSeconds > Double(input.thresholdSeconds) else { return nil }

    let payload = PolicyAction.DecisionPayload(
      id: task.id,
      severity: .needsUser,
      ruleID: id,
      sessionID: sessionID,
      agentID: nil,
      taskID: task.id,
      summary: "Task \(task.id) has been unassigned for over \(input.thresholdSeconds)s.",
      contextJSON: contextJSON(
        sessionID: sessionID,
        taskID: task.id,
        thresholdSeconds: input.thresholdSeconds,
        snapshotID: input.snapshotID
      ),
      suggestedActionsJSON: suggestedActionsJSON(taskID: task.id, agents: input.activeAgents)
    )
    let action = PolicyAction.queueDecision(payload)
    guard !context.recentActionKeys.contains(action.actionKey) else { return nil }
    return action
  }

  private func contextJSON(
    sessionID: String,
    taskID: String,
    thresholdSeconds: Int,
    snapshotID: String
  ) -> String {
    let object: [String: Any] = [
      "sessionID": sessionID,
      "snapshotID": snapshotID,
      "taskID": taskID,
      "unassignedThreshold": thresholdSeconds,
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }

  private func suggestedActionsJSON(taskID: String, agents: [AgentSnapshot]) -> String {
    let actions = agents.map { agent in
      SuggestedAction(
        id: "assign-\(taskID)-\(agent.id)",
        title: "Assign to \(agent.id)",
        kind: .assignTask,
        payloadJSON: #"{"agentID":"\#(agent.id)","taskID":"\#(taskID)"}"#
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard
      let data = try? encoder.encode(actions),
      let string = String(data: data, encoding: .utf8)
    else {
      return "[]"
    }
    return string
  }
}

private struct ActionInput {
  let activeAgents: [AgentSnapshot]
  let snapshotID: String
  let thresholdSeconds: Int
}
