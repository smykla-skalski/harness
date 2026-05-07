import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  var pendingDecisionAttentionByAgentID: [String: AcpDecisionAttention] {
    store.acpDecisionAttentionSnapshot.byAgentID
  }
}
