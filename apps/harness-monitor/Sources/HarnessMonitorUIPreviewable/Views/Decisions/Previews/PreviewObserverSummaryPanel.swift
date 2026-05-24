import HarnessMonitorKit
import SwiftUI

#Preview("Observer summary panel") {
  ObserverSummaryPanel(
    scope: DecisionWorkspaceScope(
      decisions: [
        Decision(
          id: "preview-critical",
          severity: .critical,
          ruleID: "preview-rule-critical",
          sessionID: "session-leader",
          agentID: nil,
          taskID: nil,
          summary: "Leader session has stalled for 18 minutes",
          contextJSON: "{}",
          suggestedActionsJSON: "[]"
        ),
        Decision(
          id: "preview-needs-user",
          severity: .needsUser,
          ruleID: "preview-rule-needs-user",
          sessionID: "session-leader",
          agentID: nil,
          taskID: nil,
          summary: "Codex approval is waiting for operator input",
          contextJSON: "{}",
          suggestedActionsJSON: "[]"
        ),
      ],
      filters: .init(query: "", severities: [], scope: .summary)
    ),
    observer: PreviewFixtures.observer
  )
  .padding()
  .frame(width: 560)
}

#Preview("Observer empty state") {
  ObserverSummaryEmptyState()
    .padding()
    .frame(width: 560)
}
