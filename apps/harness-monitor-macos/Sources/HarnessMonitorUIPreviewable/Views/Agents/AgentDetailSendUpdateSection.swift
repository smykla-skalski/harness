import HarnessMonitorKit
import SwiftUI

private enum AgentDetailSendUpdateFocusField: Hashable {
  case customCommand
}

struct AgentDetailSendUpdateSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String

  @Binding var selectedSendAction: SendUpdateAction
  @Binding var signalCommand: String
  @Binding var signalMessage: String
  @Binding var signalActionHint: String
  @FocusState private var focusedField: AgentDetailSendUpdateFocusField?
  @State private var isMoreOptionsExpanded = false

  private var trimmedCommand: String {
    signalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedMessage: String {
    signalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func statusMessage(
    isSessionReadOnly: Bool,
    trimmedCommand: String,
    trimmedMessage: String
  ) -> String? {
    if isSessionReadOnly {
      return "Read-only session — open a writable session to send updates."
    }
    if trimmedCommand.isEmpty {
      return "Pick or type an update type."
    }
    if trimmedMessage.isEmpty {
      return "Type a message to send."
    }
    return nil
  }

  static func prefersExpandedAdvancedOptions(
    selectedSendAction: SendUpdateAction,
    actionHint: String
  ) -> Bool {
    selectedSendAction == .custom
      || !actionHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var statusMessage: String? {
    Self.statusMessage(
      isSessionReadOnly: store.isSessionReadOnly,
      trimmedCommand: trimmedCommand,
      trimmedMessage: trimmedMessage
    )
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
    return "Send"
  }

  private var isSessionReadOnly: Bool {
    store.isSessionReadOnly
  }

  private var moreOptionsSummary: String? {
    switch (selectedSendAction == .custom, trimmedActionHint != nil) {
    case (true, true):
      "Custom type · Context added"
    case (true, false):
      "Custom type"
    case (false, true):
      "Context added"
    case (false, false):
      nil
    }
  }

  private var deadlineStatusLabel: String? {
    guard let deadlinePresentation, !deadlinePresentation.isUrgent else {
      return nil
    }
    return "Deadline \(deadlinePresentation.countdownLabel)"
  }

  private var statusTint: Color {
    isSessionReadOnly ? HarnessMonitorTheme.secondaryInk : HarnessMonitorTheme.caution
  }

  private var statusSymbolName: String {
    isSessionReadOnly ? "lock.fill" : "exclamationmark.circle"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      compactComposer
      advancedOptionsDisclosure
      if statusMessage != nil || deadlineStatusLabel != nil {
        composerStatusRow
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .onAppear {
      if Self.prefersExpandedAdvancedOptions(
        selectedSendAction: selectedSendAction,
        actionHint: signalActionHint
      ) {
        isMoreOptionsExpanded = true
      }
    }
    .onChange(of: selectedSendAction) { _, newValue in
      if newValue == .custom {
        isMoreOptionsExpanded = true
        focusedField = .customCommand
      } else if focusedField == .customCommand {
        focusedField = nil
      }
    }
    .onChange(of: signalActionHint) { _, newValue in
      if Self.prefersExpandedAdvancedOptions(
        selectedSendAction: selectedSendAction,
        actionHint: newValue
      ) {
        isMoreOptionsExpanded = true
      }
    }
  }

  @ViewBuilder private var compactComposer: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        updateTypePicker
          .frame(maxWidth: 180, alignment: .leading)
        messageField
        sendButton
      }

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        updateTypePicker
        messageField
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          Spacer(minLength: 0)
          sendButton
        }
      }
    }
  }

  private var updateTypePicker: some View {
    Picker("Update type", selection: $selectedSendAction) {
      ForEach(SendUpdateAction.allLabeledCases, id: \.self) { action in
        Text(action.humanLabel).tag(action)
      }
    }
    .labelsHidden()
    .harnessNativeFormControl()
    .accessibilityLabel("Update type")
    .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailSignalCommand)
    .disabled(isSessionReadOnly)
  }

  private var messageField: some View {
    TextField("Tell this agent what to do next", text: $signalMessage, axis: .vertical)
      .harnessNativeFormControl()
      .lineLimit(1...3)
      .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailSignalMessage)
      .accessibilityLabel("Message")
      .submitLabel(.send)
      .disabled(isSessionReadOnly)
  }

  private var advancedOptionsDisclosure: some View {
    DisclosureGroup(isExpanded: $isMoreOptionsExpanded) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        if selectedSendAction == .custom {
          AgentDetailFieldBlock(title: "Custom update type") {
            TextField("Custom update type", text: $signalCommand)
              .harnessNativeFormControl()
              .submitLabel(.send)
              .accessibilityLabel("Custom update type")
              .focused($focusedField, equals: .customCommand)
              .disabled(isSessionReadOnly)
          }
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
          .disabled(isSessionReadOnly)
        }
      }
      .padding(.top, HarnessMonitorTheme.spacingXS)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: "slider.horizontal.3")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityHidden(true)
        Text("More update options")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        if let moreOptionsSummary {
          Text(moreOptionsSummary)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailSignalDisclosure)
  }

  @ViewBuilder private var composerStatusRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        if let statusMessage {
          composerStatusLabel(statusMessage)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        if let deadlineStatusLabel {
          composerDeadlineLabel(deadlineStatusLabel)
        }
      }

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        if let statusMessage {
          composerStatusLabel(statusMessage)
        }
        if let deadlineStatusLabel {
          composerDeadlineLabel(deadlineStatusLabel)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceDetailSignalStatus)
  }

  private func composerStatusLabel(_ label: String) -> some View {
    Label {
      Text(label)
        .scaledFont(.caption)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: statusSymbolName)
        .scaledFont(.caption.weight(.semibold))
        .accessibilityHidden(true)
    }
    .foregroundStyle(statusTint)
    .accessibilityElement(children: .combine)
  }

  private func composerDeadlineLabel(_ label: String) -> some View {
    Label {
      Text(label)
        .scaledFont(.caption)
        .lineLimit(1)
    } icon: {
      Image(systemName: "clock")
        .scaledFont(.caption.weight(.semibold))
        .accessibilityHidden(true)
    }
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Prompt deadline")
    .accessibilityValue(deadlinePresentation?.accessibilityLabel ?? label)
  }

  private var sendButton: some View {
    HarnessInlineActionButton(
      title: sendButtonTitle,
      actionID: .sendSignal(sessionID: sessionID, agentID: agentID),
      store: store,
      variant: .prominent,
      tint: nil,
      isExternallyDisabled: statusMessage != nil,
      accessibilityIdentifier: HarnessMonitorAccessibility.workspaceDetailSignalSend,
      action: dispatchSendUpdate
    )
    .accessibilityLabel("Send Update")
    .accessibilityValue(statusMessage ?? "")
  }

  private func dispatchSendUpdate() {
    guard statusMessage == nil else { return }
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
        let agentName =
          store
          .selectedSession?
          .agents
          .first(where: { $0.agentId == agentID })?
          .name ?? agentID
        let preview =
          dispatchedMessage.isEmpty
          ? dispatchedCommand
          : dispatchedMessage
        let truncated =
          preview.count > 80
          ? String(preview.prefix(80)) + "…"
          : preview
        store.presentSuccessFeedback("Update sent to \(agentName) — \(truncated)")
      }
    }
  }
}
