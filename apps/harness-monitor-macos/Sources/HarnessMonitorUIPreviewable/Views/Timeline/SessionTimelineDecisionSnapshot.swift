import Foundation
import HarnessMonitorKit
import SwiftUI

enum SessionTimelineSignalPayload: Equatable, Sendable {
  case cancel(signalID: String, agentID: String)
  case resend(record: SessionSignalRecord)
}

struct SessionTimelineAction: Identifiable, Equatable, Sendable {
  let decisionID: String
  let id: String
  let title: String
  let kind: SuggestedAction.Kind
  let payloadJSON: String
  let isPrimary: Bool
  let signalPayload: SessionTimelineSignalPayload?

  init(
    decisionID: String,
    id: String,
    title: String,
    kind: SuggestedAction.Kind,
    payloadJSON: String,
    isPrimary: Bool
  ) {
    self.decisionID = decisionID
    self.id = id
    self.title = title
    self.kind = kind
    self.payloadJSON = payloadJSON
    self.isPrimary = isPrimary
    self.signalPayload = nil
  }

  static func cancelSignal(signalID: String, agentID: String) -> Self {
    Self(
      decisionID: "",
      id: "cancel-\(signalID)",
      title: "Cancel",
      kind: .dismiss,
      payloadJSON: "{}",
      isPrimary: false,
      signalPayload: .cancel(signalID: signalID, agentID: agentID)
    )
  }

  static func resendSignal(_ record: SessionSignalRecord) -> Self {
    Self(
      decisionID: "",
      id: "resend-\(record.signal.signalId)",
      title: "Resend",
      kind: .dismiss,
      payloadJSON: "{}",
      isPrimary: true,
      signalPayload: .resend(record: record)
    )
  }

  var accessibilityIdentifier: String {
    HarnessMonitorAccessibility.sessionTimelineActionButton(
      decisionID: decisionID,
      actionID: id
    )
  }

  var role: ButtonRole? {
    signalPayload != nil ? nil : (kind == .dismiss ? .destructive : nil)
  }

  @MainActor
  func perform(using handler: any DecisionActionHandler) async {
    if let sp = signalPayload {
      switch sp {
      case .cancel(let signalID, let agentID):
        await handler.cancelSignal(signalID: signalID, agentID: agentID)
      case .resend(let record):
        await handler.resendSignal(record)
      }
      return
    }
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

  private init(
    decisionID: String,
    id: String,
    title: String,
    kind: SuggestedAction.Kind,
    payloadJSON: String,
    isPrimary: Bool,
    signalPayload: SessionTimelineSignalPayload?
  ) {
    self.decisionID = decisionID
    self.id = id
    self.title = title
    self.kind = kind
    self.payloadJSON = payloadJSON
    self.isPrimary = isPrimary
    self.signalPayload = signalPayload
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
