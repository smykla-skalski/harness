import HarnessMonitorKit
import SwiftUI

struct AgentDetailRoleActionsSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String
  let isLeader: Bool
  let roleActionsAvailable: Bool
  let rolePickerValues: [SessionRole]

  @Binding var rolePickerSelection: SessionRole

  private var disabledReason: String {
    if isLeader {
      "Transfer leadership before changing the leader's role or removing this agent."
    } else if !roleActionsAvailable {
      "Role actions are unavailable for this session."
    } else {
      ""
    }
  }

  var body: some View {
    if !roleActionsAvailable {
      AgentDetailEmptyState(
        title: "Role actions unavailable",
        systemImage: "lock.slash",
        description: disabledReason,
        nextStep: "Switch to a session that supports leadership changes.",
        tint: HarnessMonitorTheme.caution
      )
    } else if isLeader {
      AgentDetailEmptyState(
        title: "Leader role is fixed",
        systemImage: "crown",
        description: "The leader role cannot be changed while this agent leads the session.",
        nextStep: "Transfer leadership to another agent before removing this one.",
        tint: HarnessMonitorTheme.warmAccent
      )
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        AgentDetailFieldBlock(title: "Role") {
          Picker("Role", selection: $rolePickerSelection) {
            ForEach(rolePickerValues, id: \.self) { role in
              Text(role.title).tag(role)
            }
          }
          .labelsHidden()
          .harnessNativeFormControl()
          .accessibilityLabel("Role")
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentDetailRolePicker)
        }
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          HarnessInlineActionButton(
            title: "Change Role",
            actionID: .changeRole(sessionID: sessionID, agentID: agentID),
            store: store,
            variant: .prominent,
            tint: nil,
            isExternallyDisabled: false,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentDetailRoleChange,
            action: {
              Task {
                _ = await store.changeRole(agentID: agentID, role: rolePickerSelection)
              }
            }
          )
          HarnessInlineActionButton(
            title: "Remove Agent",
            actionID: .removeAgent(sessionID: sessionID, agentID: agentID),
            store: store,
            variant: .bordered,
            tint: .red,
            isExternallyDisabled: false,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentDetailRoleRemove,
            action: { store.requestRemoveAgentConfirmation(agentID: agentID) }
          )
        }
      }
    }
  }
}
