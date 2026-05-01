import Foundation

extension WorkspaceWindowView {
  static func pendingPromptQuestionHead(_ question: String) -> String {
    let firstLine =
      question
      .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let firstLine, !firstLine.isEmpty {
      return firstLine
    }
    return "the pending user prompt"
  }
}
