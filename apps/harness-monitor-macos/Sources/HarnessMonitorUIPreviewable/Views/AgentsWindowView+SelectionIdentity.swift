extension AgentsWindowView {
  var scrollContainerIdentity: String {
    switch viewModel.selection {
    case .create:
      "create"
    case .terminal(let sessionID):
      "terminal:\(sessionID)"
    case .codex(let runID):
      "codex:\(runID)"
    case .agent(let agentID):
      "agent:\(agentID)"
    case .task(let taskID):
      "task:\(taskID)"
    }
  }
}
