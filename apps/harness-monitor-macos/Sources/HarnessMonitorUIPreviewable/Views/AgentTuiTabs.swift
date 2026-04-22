enum AgentTuiCreateMode: String, CaseIterable, Identifiable {
  case terminal
  case codex

  var id: String { rawValue }

  var title: String {
    switch self {
    case .terminal:
      "Terminal"
    case .codex:
      "Codex"
    }
  }
}
