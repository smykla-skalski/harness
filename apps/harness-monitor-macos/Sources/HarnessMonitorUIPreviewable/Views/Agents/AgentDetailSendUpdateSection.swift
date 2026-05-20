import HarnessMonitorKit
import SwiftUI

private enum AgentDetailSendUpdateFocusField: Hashable {
  case customCommand
}

struct AgentDetailSendUpdateSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String
  let agentName: String?
  let actionActorID: String?
  let actionUnavailableMessage: String?
  let runtimeState: AcpAgentRuntimeState?

  @Binding var selectedSendAction: SendUpdateAction
  @Binding var signalCommand: String
  @Binding var signalMessage: String
  @Binding var signalActionHint: String
  @FocusState private var focusedField: AgentDetailSendUpdateFocusField?
  @State private var deadlineClock = AgentDetailDeadlineClockState()
  @State private var isMoreOptionsExpanded = false
  // Measured container width drives the deterministic horizontal/vertical pick
  // below. ViewThatFits would build both candidate trees on every body
  // invocation; here we measure once and only re-pick on threshold crossings.
  @State private var composerFitsHorizontally = true

  private static let composerHorizontalMinWidth: CGFloat = 480

  init(
    store: HarnessMonitorStore,
    sessionID: String,
    agentID: String,
    agentName: String? = nil,
    actionActorID: String? = nil,
    actionUnavailableMessage: String? = nil,
    runtimeState: AcpAgentRuntimeState? = nil,
    selectedSendAction: Binding<SendUpdateAction>,
    signalCommand: Binding<String>,
    signalMessage: Binding<String>,
    signalActionHint: Binding<String>
  ) {
    self.store = store
    self.sessionID = sessionID
    self.agentID = agentID
    self.agentName = agentName
    self.actionActorID = actionActorID
    self.actionUnavailableMessage = actionUnavailableMessage
    self.runtimeState = runtimeState
    _selectedSendAction = selectedSendAction
    _signalCommand = signalCommand
    _signalMessage = signalMessage
    _signalActionHint = signalActionHint
  }

  private var trimmedCommand: String {
    signalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedMessage: String {
    signalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var statusMessage: String? {
    Self.statusMessage(
      isSessionReadOnly: store.isSessionReadOnly,
      actionUnavailableMessage: actionUnavailableMessage,
      trimmedCommand: trimmedCommand,
      trimmedMessage: trimmedMessage
    )
  }

  private var trimmedActionHint: String? {
    let trimmed = signalActionHint.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var promptDeadlineDate: Date? {
    guard
      let runtimeState = runtimeState ?? store.acpRuntimeState(for: agentID),
      let observedAt = runtimeState.promptDeadlineAnchorAt,
      let remaining = runtimeState.promptDeadlineRemainingMs
    else {
      return nil
    }
    return observedAt.addingTimeInterval(TimeInterval(remaining) / 1000)
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

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      compactComposer
      advancedOptionsDisclosure
      if statusMessage != nil || promptDeadlineDate != nil {
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
    .task(id: promptDeadlineDate) {
      await deadlineClock.run(store: store, deadline: promptDeadlineDate)
    }
  }

  @ViewBuilder private var compactComposer: some View {
    Group {
      if composerFitsHorizontally {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
          updateTypePicker
            .frame(maxWidth: 180, alignment: .leading)
          messageField
          sendButton
        }
      } else {
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
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      let next = width >= Self.composerHorizontalMinWidth
      if composerFitsHorizontally != next {
        composerFitsHorizontally = next
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
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentDetailSignalCommand)
    .disabled(isSessionReadOnly)
  }

  private var messageField: some View {
    TextField("Tell this agent what to do next", text: $signalMessage, axis: .vertical)
      .harnessNativeFormControl()
      .lineLimit(1...3)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentDetailSignalMessage)
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
          help: "Add extra framing only if it helps the agent act on the update"
        ) {
          TextField(
            "Constraints, acceptance criteria, or related context",
            text: $signalActionHint
          )
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentDetailSignalAction)
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
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentDetailSignalDisclosure)
  }

  private var sendButton: some View {
    AgentDetailDeadlineSendButton(
      store: store,
      sessionID: sessionID,
      agentID: agentID,
      statusMessage: statusMessage,
      promptDeadlineDate: promptDeadlineDate,
      deadlineClock: deadlineClock,
      action: dispatchSendUpdate
    )
  }

  private var composerStatusRow: some View {
    AgentDetailComposerStatusRow(
      store: store,
      statusMessage: statusMessage,
      statusTint: statusTint,
      statusSymbolName: statusSymbolName,
      promptDeadlineDate: promptDeadlineDate,
      deadlineClock: deadlineClock
    )
  }

  private func dispatchSendUpdate() {
    guard statusMessage == nil else { return }
    let dispatchedCommand = trimmedCommand
    let dispatchedMessage = trimmedMessage
    let dispatchedActionHint = trimmedActionHint
    Task {
      let success =
        if let actionActorID {
          await store.sendSignal(
            agentID: agentID,
            command: dispatchedCommand,
            message: dispatchedMessage,
            actionHint: dispatchedActionHint,
            actor: actionActorID
          )
        } else {
          await store.sendSignal(
            agentID: agentID,
            command: dispatchedCommand,
            message: dispatchedMessage,
            actionHint: dispatchedActionHint
          )
        }
      if success {
        let selectedSessionAgentName =
          store.selectedSession?.agents.first(where: { $0.agentId == agentID })?.name
        let agentName =
          agentName
          ?? selectedSessionAgentName
          ?? agentID
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
