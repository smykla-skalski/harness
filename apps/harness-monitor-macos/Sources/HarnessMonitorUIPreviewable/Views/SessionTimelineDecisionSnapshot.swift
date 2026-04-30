import Foundation
import HarnessMonitorKit
import SwiftUI

struct SessionTimelineAction: Identifiable, Equatable, Sendable {
  let decisionID: String
  let id: String
  let title: String
  let kind: SuggestedAction.Kind
  let payloadJSON: String
  let isPrimary: Bool

  var accessibilityIdentifier: String {
    HarnessMonitorAccessibility.sessionTimelineActionButton(
      decisionID: decisionID,
      actionID: id
    )
  }

  var role: ButtonRole? {
    kind == .dismiss ? .destructive : nil
  }

  @MainActor
  func perform(using handler: any DecisionActionHandler) async {
    switch kind {
    case .snooze:
      await handler.snooze(decisionID: decisionID, duration: snoozeDuration)
    case .dismiss:
      await handler.dismiss(decisionID: decisionID)
    default:
      await handler.resolve(
        decisionID: decisionID,
        outcome: DecisionOutcome(chosenActionID: id, note: nil)
      )
    }
  }

  private var snoozeDuration: TimeInterval {
    guard let data = payloadJSON.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let duration = object["duration"] as? Double,
      duration > 0
    else {
      return 60 * 60
    }
    return duration
  }
}

struct SessionTimelineDecisionSnapshot: Identifiable, Equatable, Sendable {
  let id: String
  let severity: DecisionSeverity
  let ruleID: String
  let sessionID: String?
  let agentID: String?
  let taskID: String?
  let summary: String
  let createdAt: Date
  let actions: [SessionTimelineAction]

  init(decision: Decision) {
    id = decision.id
    severity = DecisionSeverity(rawValue: decision.severityRaw) ?? .info
    ruleID = decision.ruleID
    sessionID = decision.sessionID
    agentID = decision.agentID
    taskID = decision.taskID
    summary = decision.summary
    createdAt = decision.createdAt
    actions = Self.actions(for: decision)
  }

  var severityLabel: String {
    switch severity {
    case .info:
      "Info"
    case .warn:
      "Warn"
    case .needsUser:
      "Needs user"
    case .critical:
      "Critical"
    }
  }

  private static func actions(for decision: Decision) -> [SessionTimelineAction] {
    let parsedActions = parseActions(from: decision.suggestedActionsJSON)
    let effectiveActions = effectiveActions(for: decision, parsedActions: parsedActions)
    let primaryActionID =
      effectiveActions.first(where: isProminentActionCandidate)?.id ?? effectiveActions.first?.id
    return effectiveActions.map { action in
      SessionTimelineAction(
        decisionID: decision.id,
        id: action.id,
        title: action.title,
        kind: action.kind,
        payloadJSON: action.payloadJSON,
        isPrimary: action.id == primaryActionID && isProminentActionCandidate(action)
      )
    }
  }

  private static func parseActions(from json: String) -> [SuggestedAction] {
    guard let data = json.data(using: .utf8),
      let actions = try? JSONDecoder().decode([SuggestedAction].self, from: data)
    else {
      return []
    }
    return actions
  }

  private static func effectiveActions(
    for decision: Decision,
    parsedActions: [SuggestedAction]
  ) -> [SuggestedAction] {
    guard decision.ruleID != AcpPermissionDecisionPayload.ruleID else {
      return parsedActions
    }
    if parsedActions.contains(where: { $0.kind == .dismiss }) {
      return parsedActions
    }
    return parsedActions + [
      SuggestedAction(
        id: "dismiss-\(decision.id)",
        title: "Dismiss",
        kind: .dismiss,
        payloadJSON: "{}"
      )
    ]
  }

  private static func isProminentActionCandidate(_ action: SuggestedAction) -> Bool {
    switch action.kind {
    case .dismiss, .snooze:
      false
    default:
      true
    }
  }
}
