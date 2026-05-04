extension WorkspaceWindowCreatePane {
  var createPaneDescription: String {
    switch viewModel.createMode {
    case .terminal:
      "Pick a provider and press Start - everything else is optional."
    case .codex:
      "Write a prompt and press Start - everything else is optional."
    }
  }
}
