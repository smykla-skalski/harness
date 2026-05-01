enum AgentTuiCreateMode: String, CaseIterable, Identifiable {
  case terminal
  case codex

  var id: String { rawValue }

  var title: String {
    switch self {
    case .terminal:
      "Agent"
    case .codex:
      "Codex Run"
    }
  }

  var headerTitle: String {
    switch self {
    case .terminal:
      "New agent"
    case .codex:
      "New Codex run"
    }
  }
}
