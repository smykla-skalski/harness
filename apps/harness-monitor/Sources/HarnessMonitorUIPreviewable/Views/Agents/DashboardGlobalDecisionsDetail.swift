import HarnessMonitorKit
import SwiftUI

struct DashboardGlobalDecisionsDetail: View {
  let store: HarnessMonitorStore
  let items: [DashboardDecisionItem]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Global decisions")
            .scaledFont(.title2.weight(.semibold))
          Text("These decisions need attention but are not tied to a loaded workspace")
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
        }

        DashboardAcpSection(title: countTitle) {
          ForEach(items) { item in
            DashboardAgentDecisionCard(store: store, item: item)
          }
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardGlobalDecisionsDetail)
  }

  private var countTitle: String {
    items.count == 1 ? "1 pending decision" : "\(items.count) pending decisions"
  }
}

extension HarnessMonitorAccessibility {
  public static let dashboardGlobalDecisionsDetail =
    "harness.dashboard.agents.global-decisions"
}
