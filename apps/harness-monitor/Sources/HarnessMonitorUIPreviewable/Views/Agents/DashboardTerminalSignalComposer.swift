import Foundation
import HarnessMonitorKit
import Observation
import SwiftUI

struct DashboardTerminalSignalToken: Equatable, Sendable {
  let id = UUID()
  let agentID: String
}

struct DashboardTerminalSignalComposer: View {
  @Bindable var state: DashboardTerminalSignalState
  let agentID: String
  let isEnabled: Bool
  let onSend: () -> Void

  var body: some View {
    DashboardAcpSection(title: "Send signal") {
      TextField("Command", text: $state.command)
        .textFieldStyle(.roundedBorder)
        .disabled(!isEnabled)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalSignalCommandField)
      TextField("Message", text: $state.message, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(3, reservesSpace: true)
        .disabled(!isEnabled)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalSignalMessageField)
      TextField("Action hint (optional)", text: $state.actionHint)
        .textFieldStyle(.roundedBorder)
        .disabled(!isEnabled)
      HStack {
        Text("Signals are delivered to the managed terminal membership")
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Send signal") { onSend() }
          .buttonStyle(.borderedProminent)
          .disabled(!canSend)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalSignalSendButton)
      }
    }
  }

  private var canSend: Bool {
    isEnabled && state.represents(agentID: agentID)
      && !state.trimmedCommand.isEmpty && !state.trimmedMessage.isEmpty
  }
}

@MainActor
@Observable
final class DashboardTerminalSignalState {
  var command = "inject_context"
  var message = ""
  var actionHint = ""
  private(set) var isSending = false
  private var representedAgentID: String?
  private var activeToken: DashboardTerminalSignalToken?

  var trimmedCommand: String {
    command.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedMessage: String {
    message.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedActionHint: String? {
    let value = actionHint.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  func represents(agentID: String) -> Bool {
    representedAgentID == agentID
  }

  func prepare(agentID: String) {
    guard representedAgentID != agentID else { return }
    representedAgentID = agentID
    activeToken = nil
    isSending = false
    message = ""
    actionHint = ""
  }

  func beginSend(agentID: String) -> DashboardTerminalSignalToken? {
    prepare(agentID: agentID)
    guard !isSending, !trimmedCommand.isEmpty, !trimmedMessage.isEmpty else { return nil }
    let token = DashboardTerminalSignalToken(agentID: agentID)
    activeToken = token
    isSending = true
    return token
  }

  func finishSend(_ token: DashboardTerminalSignalToken, succeeded: Bool) {
    guard activeToken == token else { return }
    activeToken = nil
    isSending = false
    if succeeded {
      message = ""
      actionHint = ""
    }
  }
}
