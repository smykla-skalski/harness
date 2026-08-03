import HarnessMonitorKit
import SwiftUI

/// The "Team decisions" section shown inside an agent's detail: supervisor and manual decisions
/// attributed to that agent. ACP permissions and Codex approvals keep their own runtime panels, so
/// callers pass only the items with no native home.
struct DashboardAgentDecisionsSection: View {
  let store: HarnessMonitorStore
  let items: [DashboardDecisionItem]

  var body: some View {
    if !items.isEmpty {
      DashboardAcpSection(title: items.count == 1 ? "Team decision" : "Team decisions") {
        ForEach(items) { item in
          DashboardAgentDecisionCard(store: store, item: item)
        }
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentDecisions)
    }
  }
}

extension HarnessMonitorAccessibility {
  public static let dashboardAgentDecisions = "harness.dashboard.agents.decisions"
  public static let dashboardWorkspaceDecisionsDetail = "harness.dashboard.agents.workspace-decisions"
}
