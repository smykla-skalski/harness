import Foundation

extension SupervisorService {
  static func makeQuarantineDecision(for ruleID: String) -> PolicyAction.DecisionPayload {
    PolicyAction.DecisionPayload(
      id: "quarantine:\(ruleID)",
      severity: .critical,
      ruleID: ruleID,
      sessionID: nil,
      agentID: nil,
      taskID: nil,
      summary: "Rule \(ruleID) quarantined after repeated failures",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
  }

  static func actionKey(from payloadJSON: String) -> String? {
    guard let data = payloadJSON.data(using: .utf8),
      let action = try? JSONDecoder().decode(PolicyAction.self, from: data)
    else {
      return nil
    }
    return action.actionKey
  }
}
