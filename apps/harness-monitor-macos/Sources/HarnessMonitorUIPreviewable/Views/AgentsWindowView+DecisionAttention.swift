import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  var pendingDecisionAttentionByAgentID: [String: AcpDecisionAttention] {
    store.acpDecisionAttentionSnapshot.byAgentID
  }

  func openPendingDecisions(for agentID: String) {
    store.selectOldestDecision(for: agentID)
    openWindow(id: HarnessMonitorWindowID.decisions)
  }
}
