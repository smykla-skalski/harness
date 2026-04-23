import Foundation

@testable import HarnessMonitorKit

extension DecisionDraft {
  /// Canonical test draft. Phase 2 tests call `.fixture(id: "d1")` to get a filled-in draft
  /// without redeclaring every field per test.
  static func fixture(
    id: String = "d1",
    severity: DecisionSeverity = .needsUser,
    ruleID: String = "stuck-agent",
    sessionID: String? = "s1",
    agentID: String? = "a1",
    taskID: String? = nil,
    summary: String = "agent stalled",
    contextJSON: String = "{}",
    suggestedActionsJSON: String = "[]"
  ) -> DecisionDraft {
    DecisionDraft(
      id: id,
      severity: severity,
      ruleID: ruleID,
      sessionID: sessionID,
      agentID: agentID,
      taskID: taskID,
      summary: summary,
      contextJSON: contextJSON,
      suggestedActionsJSON: suggestedActionsJSON
    )
  }
}
