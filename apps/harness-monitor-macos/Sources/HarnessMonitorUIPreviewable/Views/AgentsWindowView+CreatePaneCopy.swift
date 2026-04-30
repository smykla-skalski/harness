extension AgentsWindowView {
  var createPaneDescription: String {
    switch viewModel.createMode {
    case .terminal:
      if displayState.hasAgentTuis {
        "Open terminal agents stay pinned in the sidebar, so you can launch another one without losing the active viewport."
      } else {
        "Choose a provider, tune the launch defaults, and start a terminal-backed agent from this window."
      }
    case .codex:
      if displayState.hasCodexRuns {
        "Codex threads stay pinned in the sidebar, so you can continue active work without losing context."
      } else {
        "Write a prompt, pick the run mode, and start a Codex thread from the same Agents window."
      }
    }
  }
}
