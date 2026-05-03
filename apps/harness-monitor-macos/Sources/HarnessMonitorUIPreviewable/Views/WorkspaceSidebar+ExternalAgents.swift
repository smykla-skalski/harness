import HarnessMonitorKit
import SwiftUI

extension WorkspaceSidebar {
  @ViewBuilder
  func externalAgentRow(_ agent: AgentRegistration) -> some View {
    let pendingDecisionBadgeID =
      HarnessMonitorAccessibility.agentPendingDecisionBadge(agent.agentId)
    let attention = pendingDecisionAttention[agent.agentId]

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
          openPendingDecisions(agent.agentId)
        }
        .harnessUITestValue("count=\(attention.count) batch=\(attention.oldestBatchID)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onTapGesture {
      selection = .agent(sessionID: currentSessionID, agentID: agent.agentId)
    }
    .overlay(alignment: .topTrailing) {
      if agent.isAutoSpawned {
        AutoSpawnedBadgeView(agentID: agent.agentId)
          .allowsHitTesting(false)
      }
    }
    .padding(.vertical, rowPadding)
    .accessibilityTestProbe(
      pendingDecisionBadgeID,
      label: "Pending decisions",
      value: attention.map { "count=\($0.count) batch=\($0.oldestBatchID)" } ?? "count=0"
    )
  }

  func lastAcpMessageAt(
    for decision: Decision
  ) -> Date? {
    store.acpPermissionLastSignalAt(sessionID: decision.sessionID)
  }

  func acpPayload(
    for decision: Decision
  ) -> AcpPermissionDecisionPayload? {
    guard decision.ruleID == AcpPermissionDecisionPayload.ruleID else {
      return nil
    }
    return store.acpPermissionDecisionPayload(for: decision.id)
      ?? AcpPermissionDecisionPayload.decode(from: decision)
  }
}
