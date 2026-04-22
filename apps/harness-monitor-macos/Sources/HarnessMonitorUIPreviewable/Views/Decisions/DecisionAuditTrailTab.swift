import HarnessMonitorKit
import SwiftUI

/// Audit-trail tab rendered inside the Decisions detail column. Phase 2 worker 20 fills this
/// with the chronological `SupervisorEvent` list scoped by the active decision's
/// `sessionID`/`agentID`/`taskID`/`ruleID`.
public struct DecisionAuditTrailTab: View {
  public init() {}

  public var body: some View {
    EmptyView()
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionAuditTrail)
  }
}

#Preview("Decision Audit Trail — empty") {
  DecisionAuditTrailTab()
    .frame(width: 420, height: 320)
}
