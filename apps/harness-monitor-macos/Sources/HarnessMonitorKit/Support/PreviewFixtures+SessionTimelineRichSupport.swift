import Foundation

struct RichSessionTimelineDecisionSpec {
  let id: String
  let severity: DecisionSeverity
  let ruleID: String
  let agentID: String
  let taskID: String?
  let summary: String
  let createdAt: Date
  let actionsJSON: String
}

struct RichSessionTimelineEntrySpec {
  let id: String
  let recordedAt: String
  let kind: String
  let agentID: String?
  let taskID: String?
  let summary: String
  let payload: JSONValue
}

private struct PreviewDecisionActionSpec: Encodable {
  let id: String
  let title: String
  let kind: String
  let payloadJSON: String
}

extension PreviewFixtures {
  static let approvalActionsJSON = actionsJSON([
    PreviewDecisionActionSpec(
      id: "approve-retry",
      title: "Approve Retry",
      kind: "nudge",
      payloadJSON: "{}"
    ),
    PreviewDecisionActionSpec(
      id: "snooze-15m",
      title: "Snooze 15m",
      kind: "snooze",
      payloadJSON: #"{"duration":900}"#
    ),
    PreviewDecisionActionSpec(
      id: "dismiss-approval",
      title: "Dismiss",
      kind: "dismiss",
      payloadJSON: "{}"
    ),
  ])

  static let repairActionsJSON = actionsJSON([
    PreviewDecisionActionSpec(
      id: "assign-repair",
      title: "Assign Repair",
      kind: "assignTask",
      payloadJSON: "{}"
    ),
    PreviewDecisionActionSpec(
      id: "defer-repair",
      title: "Snooze 1h",
      kind: "snooze",
      payloadJSON: #"{"duration":3600}"#
    ),
    PreviewDecisionActionSpec(
      id: "dismiss-repair",
      title: "Dismiss",
      kind: "dismiss",
      payloadJSON: "{}"
    ),
  ])

  static let previewActionsJSON = actionsJSON([
    PreviewDecisionActionSpec(
      id: "open-preview",
      title: "Open Preview",
      kind: "custom",
      payloadJSON: "{}"
    ),
    PreviewDecisionActionSpec(
      id: "dismiss-preview",
      title: "Dismiss",
      kind: "dismiss",
      payloadJSON: "{}"
    ),
  ])

  static let idleSessionActionsJSON = actionsJSON([
    PreviewDecisionActionSpec(
      id: "idle-session.nudge.gemini-20260504124513402981000",
      title: "Send check-in nudge",
      kind: "nudge",
      payloadJSON: idleSessionNudgePayloadJSON
    ),
    PreviewDecisionActionSpec(
      id: "idle-session.close.nod8ccog",
      title: "Close session",
      kind: "custom",
      payloadJSON: #"{"mode":"closeSession","sessionID":"nod8ccog"}"#
    ),
    PreviewDecisionActionSpec(
      id: "dismiss-idle-session",
      title: "Dismiss",
      kind: "dismiss",
      payloadJSON: "{}"
    ),
  ])

  private static let idleSessionNudgePayloadJSON = encodedPayloadJSON(
    agentID: "gemini-20260504124513402981000",
    input: "Quick check-in from Harness Monitor supervisor for idle session nod8ccog"
  )

  private static func actionsJSON(_ actions: [PreviewDecisionActionSpec]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(actions) else {
      preconditionFailure("Failed to encode preview decision actions")
    }
    guard let json = String(bytes: data, encoding: .utf8) else {
      preconditionFailure("Failed to decode preview decision actions as UTF-8")
    }
    return json
  }

  private static func encodedPayloadJSON(agentID: String, input: String) -> String {
    let payload = ["agentID": agentID, "input": input]
    let data = try? JSONSerialization.data(
      withJSONObject: payload,
      options: [.sortedKeys]
    )
    guard let data else {
      preconditionFailure("Failed to encode preview payload")
    }
    guard let json = String(bytes: data, encoding: .utf8) else {
      preconditionFailure("Failed to decode preview payload as UTF-8")
    }
    return json
  }

  static func sessionTimelineDecision(_ spec: RichSessionTimelineDecisionSpec) -> Decision {
    let decision = Decision(
      id: spec.id,
      severity: spec.severity,
      ruleID: spec.ruleID,
      sessionID: Self.summary.sessionId,
      agentID: spec.agentID,
      taskID: spec.taskID,
      summary: spec.summary,
      contextJSON: "{}",
      suggestedActionsJSON: spec.actionsJSON
    )
    decision.createdAt = spec.createdAt
    return decision
  }

  static func sessionTimelineEntry(_ spec: RichSessionTimelineEntrySpec) -> TimelineEntry {
    TimelineEntry(
      entryId: spec.id,
      recordedAt: spec.recordedAt,
      kind: spec.kind,
      sessionId: Self.summary.sessionId,
      agentId: spec.agentID,
      taskId: spec.taskID,
      summary: spec.summary,
      payload: spec.payload
    )
  }

  static func previewDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) else {
      preconditionFailure("Invalid preview fixture date: \(value)")
    }
    return date
  }
}
