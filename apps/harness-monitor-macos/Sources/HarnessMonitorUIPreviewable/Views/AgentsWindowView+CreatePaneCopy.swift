extension AgentsWindowView {
  var createPaneDescription: String {
    switch viewModel.createMode {
    case .terminal:
      if displayState.hasAgentTuis {
        "Open terminal-backed agents stay pinned in the sidebar so you can launch "
          + "another agent without losing the active viewport."
      } else {
        "Start a terminal-backed agent to inspect the live screen and steer it from Harness Monitor."
      }
    case .codex:
      if displayState.hasCodexRuns {
        "Codex threads stay pinned in the sidebar so you can continue active work without losing context."
      } else {
        "Start a Codex thread to investigate, patch, or route approvals from the same Agents window."
      }
    }
  }
}
