import Foundation

enum SessionWindowCreateFormValidation {
  static func message(for draft: SessionCreateDraft) -> String? {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      return "\(draft.kind.title) name is required."
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
