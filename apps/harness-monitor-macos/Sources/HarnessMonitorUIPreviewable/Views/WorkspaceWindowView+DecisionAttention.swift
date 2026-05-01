import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  var pendingDecisionAttentionByAgentID: [String: AcpDecisionAttention] {
    store.acpDecisionAttentionSnapshot.byAgentID
  }

  func openPendingDecisions(for agentID: String) {
    if let decisionID = store.selectOldestDecision(for: agentID) {
      store.requestWorkspaceDecisionSelection(decisionID: decisionID)
      store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
    }
    openWindow(id: HarnessMonitorWindowID.workspace)
  }
}
