import HarnessMonitorKit

extension AgentDetailSendUpdateSection {
  static func statusMessage(
    isSessionReadOnly: Bool,
    actionUnavailableMessage: String?,
    trimmedCommand: String,
    trimmedMessage: String
  ) -> String? {
    if isSessionReadOnly {
      return "Read-only session — open a writable session to send updates."
    }
    if let actionUnavailableMessage {
      return actionUnavailableMessage
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
}
