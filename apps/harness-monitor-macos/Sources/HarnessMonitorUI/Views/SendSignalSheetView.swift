import HarnessMonitorKit
import SwiftUI

struct SendSignalSheetView: View {
  let store: HarnessMonitorStore
  let agentID: String
  @Environment(\.dismiss)
  private var dismiss
  @State private var command = "inject_context"
  @State private var message = ""
  @State private var actionHint = ""
  @State private var isSubmitting = false
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case command
    case message
    case actionHint
  }

  private var agent: AgentRegistration? {
    store.selectedSession?.agents.first { $0.agentId == agentID }
  }

  private var canSubmit: Bool {
    !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSubmitting
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      formContent
        .padding(HarnessMonitorTheme.spacingLG)
      Divider()
      footer
    }
    .frame(minWidth: 420, idealWidth: 500, minHeight: 300)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sendSignalSheet)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Send Signal")
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text("to \(agent?.name ?? agentID)")
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var formContent: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Text("Command")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        TextField("Command", text: $command)
          .harnessNativeFormControl()
          .focused($focusedField, equals: .command)
          .submitLabel(.next)
          .onSubmit { focusedField = .message }
          .accessibilityIdentifier(HarnessMonitorAccessibility.sendSignalSheetCommandField)
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        HStack {
          Text("Message")
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Spacer()
          HarnessVoiceInputButton(
            store: store,
            text: $message,
            label: "Dictate signal message",
            routeTarget: {
              let trimmedHint = actionHint.trimmingCharacters(in: .whitespacesAndNewlines)
              return VoiceRouteTarget.signal(
                agentID: agentID,
                command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                actionHint: trimmedHint.isEmpty ? nil : trimmedHint
              )
            },
            accessibilityIdentifier: HarnessMonitorAccessibility.sendSignalSheetMessageVoiceButton
          )
        }
        TextField("Message", text: $message, axis: .vertical)
          .harnessNativeFormControl()
          .focused($focusedField, equals: .message)
          .lineLimit(4, reservesSpace: true)
          .submitLabel(.next)
          .onSubmit { focusedField = .actionHint }
          .accessibilityIdentifier(HarnessMonitorAccessibility.sendSignalSheetMessageField)
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Text("Action Hint")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        TextField("Action Hint", text: $actionHint)
          .harnessNativeFormControl()
          .focused($focusedField, equals: .actionHint)
          .submitLabel(.done)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sendSignalSheetActionHintField)
      }
    }
  }

  private var footer: some View {
    HStack {
      Button("Cancel") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sendSignalSheetCancelButton)
      Spacer()
      HarnessInlineActionButton(
        title: "Send Signal",
        actionID: .sendSignal(
          sessionID: store.selectedSessionID ?? "",
          agentID: agentID
        ),
        store: store,
        variant: .prominent,
        tint: nil,
        isExternallyDisabled: !canSubmit,
        accessibilityIdentifier: HarnessMonitorAccessibility.sendSignalSheetSubmitButton,
        action: submit
      )
      .keyboardShortcut(.defaultAction)
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  private func submit() {
    isSubmitting = true
    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedHint = actionHint.trimmingCharacters(in: .whitespacesAndNewlines)

    Task {
      let success = await store.sendSignal(
        agentID: agentID,
        command: trimmedCommand,
        message: trimmedMessage,
        actionHint: trimmedHint.isEmpty ? nil : trimmedHint
      )
      isSubmitting = false
      if success {
        dismiss()
      }
    }
  }
}
