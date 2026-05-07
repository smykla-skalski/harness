import HarnessMonitorKit
import SwiftUI

struct WorkspaceSidebarExternalAgentRow: View {
  let store: HarnessMonitorStore
  @Binding var selection: WorkspaceSelection
  let agent: AgentRegistration
  let currentSessionID: String?
  let rowPadding: CGFloat
  let attention: AcpDecisionAttention?

  @Environment(\.openWindow)
  private var openWindow

  private var rowSelection: WorkspaceSelection {
    .agent(sessionID: currentSessionID, agentID: agent.agentId)
  }

  private var pendingDecisionBadgeID: String {
    HarnessMonitorAccessibility.agentPendingDecisionBadge(agent.agentId)
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "person.crop.circle")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      VStack(alignment: .leading, spacing: 2) {
        Text(agent.name)
          .scaledFont(.body)
        Text("\(runtimeDisplayLabel(agent.runtime)) • \(agent.role.title)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if let attention {
        AgentAttentionBadge(
          count: attention.count,
          accessibilityIdentifier: HarnessMonitorUITestEnvironment
            .accessibilityMarkersEnabled ? nil : pendingDecisionBadgeID
        ) {
          openPendingDecisions()
        }
        .harnessUITestValue("count=\(attention.count) batch=\(attention.oldestBatchID)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .topTrailing) {
      if agent.isAutoSpawned {
        AutoSpawnedBadgeView(agentID: agent.agentId)
          .allowsHitTesting(false)
      }
    }
    .padding(.vertical, rowPadding)
    .tag(rowSelection)
    .harnessMCPTab(
      HarnessMonitorAccessibility.agentTuiExternalTab(agent.agentId),
      label: agent.name,
      pressAction: {
        selection = rowSelection
      }
    )
    .accessibilityFrameMarker(
      "\(HarnessMonitorAccessibility.agentTuiExternalTab(agent.agentId)).frame"
    )
    .accessibilityTestProbe(
      pendingDecisionBadgeID,
      label: "Pending decisions",
      value: attention.map { "count=\($0.count) batch=\($0.oldestBatchID)" } ?? "count=0"
    )
  }

  private func openPendingDecisions() {
    if let decisionID = store.selectOldestDecision(for: agent.agentId) {
      store.requestWorkspaceDecisionSelection(decisionID: decisionID)
      store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
      openWindow.openHarnessDecisionSession(decisionID: decisionID, store: store)
    } else {
      openWindow.openHarnessSessionWindow(sessionID: store.selectedSessionID)
    }
  }
}
