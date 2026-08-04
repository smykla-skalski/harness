import HarnessMonitorKit
import SwiftUI

/// Detail pane for a workspace's agent-less decisions — work-item and workspace-scoped rows that
/// name no loaded agent. Reuses the same daemon-confirmed decision card as the per-agent section.
struct DashboardWorkspaceDecisionsDetail: View {
  let store: HarnessMonitorStore
  let bucket: DashboardDecisionWorkspaceBucket

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        DashboardAcpSection(title: countTitle) {
          ForEach(bucket.items) { item in
            DashboardAgentDecisionCard(store: store, item: item)
          }
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardWorkspaceDecisionsDetail)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("Workspace decisions")
          .scaledFont(.title2.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer()
      }
      HStack(spacing: 8) {
        Label(bucket.workspace.title, systemImage: "folder")
        Text("·").foregroundStyle(.tertiary)
        Text(bucket.workspace.subtitle)
      }
      .scaledFont(.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(1)

      Text("These decisions name this workspace or a work item rather than a running agent")
        .scaledFont(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var countTitle: String {
    bucket.items.count == 1 ? "1 pending decision" : "\(bucket.items.count) pending decisions"
  }
}
