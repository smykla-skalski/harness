import HarnessMonitorKit
import SwiftUI

@MainActor
private enum DecisionsSidebarPreviewFixtures {
  static let decisions: [Decision] = [
    makeDecision(
      id: "preview-critical",
      severity: .critical,
      summary: "Leader session has stalled for 18 minutes",
      sessionID: "session-leader"
    ),
    makeDecision(
      id: "preview-needs-user",
      severity: .needsUser,
      summary: "Codex approval is waiting for operator input",
      sessionID: "session-leader"
    ),
    makeDecision(
      id: "preview-warn",
      severity: .warn,
      summary: "Observer issue needs classifier teaching",
      sessionID: "session-worker"
    ),
  ]

  private static func makeDecision(
    id: String,
    severity: DecisionSeverity,
    summary: String,
    sessionID: String
  ) -> Decision {
    Decision(
      id: id,
      severity: severity,
      ruleID: "preview-rule-\(id)",
      sessionID: sessionID,
      agentID: nil,
      taskID: nil,
      summary: summary,
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
  }
}

#Preview("Decisions Sidebar — seeded") {
  DecisionsSidebar(
    decisions: DecisionsSidebarPreviewFixtures.decisions,
    selection: .constant(DecisionsSidebarPreviewFixtures.decisions.first?.id)
  )
  .frame(width: 320, height: 520)
}
