enum AgentTuiSheetSelection: Hashable {
  case create
  case terminal(String)
  case codex(String)

  var terminalID: String? {
    guard case .terminal(let terminalID) = self else {
      return nil
    }
    return terminalID
  }

  var codexRunID: String? {
    guard case .codex(let runID) = self else {
      return nil
    }
    return runID
  }
}

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
