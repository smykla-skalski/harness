import Foundation

enum SessionWindowCreateFormValidation {
  static func message(
    for draft: SessionCreateDraft,
    capabilityOptions: [AgentCapabilityOption] = []
  ) -> String? {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      return "\(draft.kind.title) name is required."
    }
    if draft.kind == .agent,
      let message = capabilityMessage(for: draft, options: capabilityOptions)
    {
      return message
    }
    return nil
  }

  private static func capabilityMessage(
    for draft: SessionCreateDraft,
    options: [AgentCapabilityOption]
  ) -> String? {
    guard !options.isEmpty else { return nil }
    let selection = draft.launchSelection
    guard
      let option = options.first(where: { option in
        option.transportChoices.contains { $0.id == selection }
      })
    else {
      return "Selected agent capability is unavailable."
    }
    let choice = option.transportChoice(for: selection)
    guard option.isEnabled(choice) else {
      return option.projectAccessGuidanceText ?? "Selected agent capability is unavailable."
    }
    return nil
  }
}

extension SessionCreateKind {
  var title: String {
    switch self {
    case .agent: "Agent"
    case .task: "Task"
    case .decision: "Decision"
    }
  }
}
