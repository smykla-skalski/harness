extension AgentsWindowView {
  var scrollContainerIdentity: String {
    switch viewModel.selection {
    case .create:
      "create"
    case .decisions(let sessionID):
      "decisions:\(sessionID ?? "none")"
    case .decision(let sessionID, let decisionID):
      "decision:\(sessionID ?? "none"):\(decisionID)"
    case .terminal(_, let terminalID):
      "terminal:\(terminalID)"
    case .codex(_, let runID):
      "codex:\(runID)"
    case .agent(_, let agentID):
      "agent:\(agentID)"
    case .task(_, let taskID):
      "task:\(taskID)"
    }
  }
}
