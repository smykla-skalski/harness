public enum AgentTuiSheetSelection: Hashable, Sendable {
  case create
  case terminal(String)
  case codex(String)
  case agent(String)
  case task(String)

  public var terminalID: String? {
    guard case .terminal(let terminalID) = self else {
      return nil
    }
    return terminalID
  }

  public var codexRunID: String? {
    guard case .codex(let runID) = self else {
      return nil
    }
    return runID
  }

  public var agentID: String? {
    guard case .agent(let agentID) = self else {
      return nil
    }
    return agentID
  }

  public var taskID: String? {
    guard case .task(let taskID) = self else {
      return nil
    }
    return taskID
  }
}
