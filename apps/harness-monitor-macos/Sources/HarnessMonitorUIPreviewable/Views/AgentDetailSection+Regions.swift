import HarnessMonitorKit
import SwiftUI

struct AgentDetailAwaitingDecisionRegion: View {
  let agentID: String
  let attention: AcpDecisionAttention
  let payload: AcpPermissionDecisionPayload?
  let isResolving: Bool
  let onApprove: () -> Void
  let onDeny: () -> Void
  let onViewAll: () -> Void

  var body: some View {
    AgentDetailAwaitingDecisionStrip(
      payload: payload,
      count: attention.count,
      isResolving: isResolving,
      approveButtonAccessibilityIdentifier:
        HarnessMonitorAccessibility.agentDetailApproveDecisionButton(agentID),
      denyButtonAccessibilityIdentifier:
        HarnessMonitorAccessibility.agentDetailDenyDecisionButton(agentID),
      viewAllButtonAccessibilityIdentifier:
        HarnessMonitorAccessibility.agentDetailOpenDecisionsButton(agentID),
      onApprove: onApprove,
      onDeny: onDeny,
      onViewAll: onViewAll
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.agentDetailAwaitingDecisionStrip(agentID)
    )
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.agentDetailAwaitingDecisionStrip(agentID),
      label: "Awaiting decision",
      value: "count=\(attention.count) batch=\(attention.oldestBatchID)"
    )
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.workspaceDetailAwaitingDecisionState,
      label: "count=\(attention.count) batch=\(attention.oldestBatchID)",
      value: agentID
    )
  }
}

struct AgentDetailRoleActionsRegion: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String
  let isLeader: Bool
  let roleActionsAvailable: Bool
  let rolePickerValues: [SessionRole]

  @Binding var rolePickerSelection: SessionRole
  @State private var isExpanded: Bool = false

  private var roleActionsLabel: String {
    isLeader ? "Role actions (leader fixed)" : "Role actions"
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      AgentDetailRoleActionsSection(
        store: store,
        sessionID: sessionID,
        agentID: agentID,
        isLeader: isLeader,
        roleActionsAvailable: roleActionsAvailable,
        rolePickerValues: rolePickerValues,
        rolePickerSelection: $rolePickerSelection
      )
      .padding(.top, HarnessMonitorTheme.spacingSM)
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: "wrench.adjustable")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.caution)
          .accessibilityHidden(true)
        Text(roleActionsLabel)
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.agentDetailRoleActionsDisclosure(agentID)
    )
  }
}

struct AgentDetailComposerRegion: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String

  @Binding var selectedSendAction: SendUpdateAction
  @Binding var signalCommand: String
  @Binding var signalMessage: String
  @Binding var signalActionHint: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Send update")
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .accessibilityAddTraits(.isHeader)
      AgentDetailSendUpdateSection(
        store: store,
        sessionID: sessionID,
        agentID: agentID,
        selectedSendAction: $selectedSendAction,
        signalCommand: $signalCommand,
        signalMessage: $signalMessage,
        signalActionHint: $signalActionHint
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, HarnessMonitorTheme.spacingLG)
    .padding(.vertical, HarnessMonitorTheme.spacingMD)
    .harnessPanelGlass()
    .overlay(alignment: .top) {
      Rectangle()
        .fill(HarnessMonitorTheme.controlBorder.opacity(0.7))
        .frame(height: 1)
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.agentDetailComposerInset(agentID)
    )
  }
}
