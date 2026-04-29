import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  var pendingDecisionAttentionByAgentID: [String: AcpDecisionAttention] {
    store.acpDecisionAttentionSnapshot.byAgentID
  }

  func openPendingDecisions(for agentID: String) {
    if let decisionID = store.selectOldestDecision(for: agentID) {
      store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
    }
    openWindow(id: HarnessMonitorWindowID.decisions)
  }
}
