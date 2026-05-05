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
          .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailRolePicker)
        }
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          HarnessInlineActionButton(
            title: "Change Role",
            actionID: .changeRole(sessionID: sessionID, agentID: agentID),
            store: store,
            variant: .prominent,
            tint: nil,
            isExternallyDisabled: false,
            accessibilityIdentifier: HarnessMonitorAccessibility.workspaceDetailRoleChange,
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
            accessibilityIdentifier: HarnessMonitorAccessibility.workspaceDetailRoleRemove,
            action: { store.requestRemoveAgentConfirmation(agentID: agentID) }
          )
        }
      }
    }
  }
}

struct AgentDetailSendUpdateSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String

  @Binding var selectedSendAction: SendUpdateAction
  @Binding var signalCommand: String
  @Binding var signalMessage: String
  @Binding var signalActionHint: String

  private var trimmedCommand: String {
    signalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedMessage: String {
    signalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var disabledReason: String? {
    if store.isSessionReadOnly {
      return "Session is read-only."
    }
    if trimmedCommand.isEmpty {
      return "Pick or type an update type."
    }
    if trimmedMessage.isEmpty {
      return "Type a message to send."
    }
    return nil
  }

  private var trimmedActionHint: String? {
    let trimmed = signalActionHint.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var promptDeadlineDate: Date? {
    guard
      let runtimeState = store.acpRuntimeState(for: agentID),
      let observedAt = runtimeState.promptDeadlineAnchorAt,
      let remaining = runtimeState.promptDeadlineRemainingMs
    else {
      return nil
    }
    return observedAt.addingTimeInterval(TimeInterval(remaining) / 1000)
  }

  private var deadlinePresentation: AcpRuntimeDeadlinePresentation? {
    guard let promptDeadlineDate else { return nil }
    return AcpRuntimeDeadlinePresentation.presentation(
      deadline: promptDeadlineDate,
      now: store.acpRuntimeClockTick
    )
  }

  private var sendButtonTitle: String {
    if let deadlinePresentation, deadlinePresentation.isUrgent {
      return "Send · \(deadlinePresentation.countdownLabel)"
    }
    return "Send Update"
  }

  var body: some View {
    if store.isSessionReadOnly {
      AgentDetailEmptyState(
        title: "Updates unavailable",
        systemImage: "lock.fill",
        description: "This session is read-only, so messages cannot be sent to the agent.",
        nextStep: "Open a writable session to nudge this agent.",
        tint: HarnessMonitorTheme.secondaryInk
      )
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        AgentDetailFieldBlock(title: "Update type") {
          Picker("Update type", selection: $selectedSendAction) {
            ForEach(SendUpdateAction.allLabeledCases, id: \.self) { action in
              Text(action.humanLabel).tag(action)
            }
          }
          .labelsHidden()
          .harnessNativeFormControl()
          .accessibilityLabel("Update type")
          .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailSignalCommand)
        }
        if selectedSendAction == .custom {
          AgentDetailFieldBlock(title: "Custom update type") {
            TextField("Custom update type", text: $signalCommand)
              .harnessNativeFormControl()
              .submitLabel(.send)
              .accessibilityLabel("Custom update type")
          }
        }
        AgentDetailFieldBlock(title: "Message") {
          TextField("Tell this agent what to do next", text: $signalMessage, axis: .vertical)
            .harnessNativeFormControl()
            .lineLimit(2, reservesSpace: true)
            .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailSignalMessage)
            .accessibilityLabel("Message")
            .submitLabel(.send)
        }
        AgentDetailFieldBlock(
          title: "Optional context",
          help: "Add extra framing only if it helps the agent act on the update."
        ) {
          TextField(
            "Constraints, acceptance criteria, or related context",
            text: $signalActionHint
          )
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailSignalAction)
          .accessibilityLabel("Optional context")
          .submitLabel(.send)
        }
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          Text(disabledReason ?? " ")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(disabledReason == nil ? 0 : 1)
            .animation(.default, value: disabledReason)
            .accessibilityHidden(disabledReason == nil)
          if let deadlinePresentation, !deadlinePresentation.isUrgent {
            Text("Deadline \(deadlinePresentation.countdownLabel)")
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityLabel("Prompt deadline")
              .accessibilityValue(deadlinePresentation.accessibilityLabel)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          HarnessInlineActionButton(
            title: sendButtonTitle,
            actionID: .sendSignal(sessionID: sessionID, agentID: agentID),
            store: store,
            variant: .prominent,
            tint: nil,
            isExternallyDisabled: disabledReason != nil,
            accessibilityIdentifier: HarnessMonitorAccessibility.workspaceDetailSignalSend,
            action: {
              let dispatchedCommand = trimmedCommand
              let dispatchedMessage = trimmedMessage
              let dispatchedActionHint = trimmedActionHint
              Task {
                let success = await store.sendSignal(
                  agentID: agentID,
                  command: dispatchedCommand,
                  message: dispatchedMessage,
                  actionHint: dispatchedActionHint
                )
                if success {
                  let agentName = store
                    .selectedSession?
                    .agents
                    .first(where: { $0.agentId == agentID })?
                    .name ?? agentID
                  let preview = dispatchedMessage.isEmpty
                    ? dispatchedCommand
                    : dispatchedMessage
                  let truncated = preview.count > 80
                    ? String(preview.prefix(80)) + "…"
                    : preview
                  store.presentSuccessFeedback("Update sent to \(agentName) — \(truncated)")
                }
              }
            }
          )
          .accessibilityLabel("Send Update")
          .accessibilityValue(disabledReason ?? "")
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
  }
}
