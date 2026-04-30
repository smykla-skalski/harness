extension AgentsWindowView {
  var createPaneDescription: String {
    switch viewModel.createMode {
    case .terminal:
      if displayState.hasAgentTuis {
        "Open agents stay pinned in the sidebar, "
          + "so you can launch another one without losing the active view."
      } else {
        "Choose a provider, tune the launch defaults, and start a new agent from this workspace."
      }
    case .codex:
      if displayState.hasCodexRuns {
        "Open runs stay pinned in the sidebar, so you can continue work without losing context."
      } else {
        "Write a prompt, pick the run mode, and start a new run from the same workspace."
      }
    }
  }
}
