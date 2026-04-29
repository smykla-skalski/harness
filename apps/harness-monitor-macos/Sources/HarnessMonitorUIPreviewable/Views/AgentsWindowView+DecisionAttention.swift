import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  var pendingDecisionAttentionByAgentID: [String: AcpDecisionAttention] {
    Dictionary(
      uniqueKeysWithValues:
        displayState.externalAgents.compactMap { agent in
          guard let attention = store.acpDecisionAttention(for: agent.agentId) else {
            return nil
          }
          return (agent.agentId, attention)
        }
    )
  }

  func openPendingDecisions(for agentID: String) {
    store.selectOldestDecision(for: agentID)
    openWindow(id: HarnessMonitorWindowID.decisions)
  }
}
