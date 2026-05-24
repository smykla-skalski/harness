import Foundation

enum SessionWindowCreateFormValidationField: Equatable {
  case capability
  case form
  case name
}

struct SessionWindowCreateFormValidationResult: Equatable {
  let message: String
  let field: SessionWindowCreateFormValidationField
}

enum SessionWindowCreateFormValidation {
  static func result(
    for draft: SessionCreateDraft,
    capabilityOptions: [AgentCapabilityOption] = []
  ) -> SessionWindowCreateFormValidationResult? {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      return .init(message: "\(draft.kind.title) name is required", field: .name)
    }
    if draft.kind == .agent,
      let message = capabilityMessage(for: draft, options: capabilityOptions)
    {
      return .init(message: message, field: .capability)
    }
    return nil
  }

  static func message(
    for draft: SessionCreateDraft,
    capabilityOptions: [AgentCapabilityOption] = []
  ) -> String? {
    result(for: draft, capabilityOptions: capabilityOptions)?.message
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
      return "Selected agent capability is unavailable"
    }
    let choice = option.transportChoice(for: selection)
    guard option.isEnabled(choice) else {
      return option.projectAccessGuidanceText ?? "Selected agent capability is unavailable"
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
