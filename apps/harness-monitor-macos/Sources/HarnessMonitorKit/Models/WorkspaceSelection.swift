public enum WorkspaceSelection: Hashable, Sendable {
  case create
  case decisions(sessionID: String?)
  case decision(sessionID: String?, decisionID: String)
  case terminal(sessionID: String?, terminalID: String)
  case codex(sessionID: String?, runID: String)
  case agent(sessionID: String?, agentID: String)
  case task(sessionID: String?, taskID: String)

  public var sessionID: String? {
    switch self {
    case .create:
      nil
    case .decisions(let sessionID),
      .decision(let sessionID, _),
      .terminal(let sessionID, _),
      .codex(let sessionID, _),
      .agent(let sessionID, _),
      .task(let sessionID, _):
      sessionID
    }
  }

  public var isDecisionRoute: Bool {
    switch self {
    case .decisions, .decision:
      true
    case .create,
      .terminal,
      .codex,
      .agent,
      .task:
      false
    }
  }

  public var decisionID: String? {
    guard case .decision(_, let decisionID) = self else {
      return nil
    }
    return decisionID
  }

  public var terminalID: String? {
    guard case .terminal(_, let terminalID) = self else {
      return nil
    }
    return terminalID
  }

  public var codexRunID: String? {
    guard case .codex(_, let runID) = self else {
      return nil
    }
    return runID
  }

  public var agentID: String? {
    guard case .agent(_, let agentID) = self else {
      return nil
    }
    return agentID
  }

  public var taskID: String? {
    guard case .task(_, let taskID) = self else {
      return nil
    }
    return taskID
  }
}

public enum WorkspaceCreateEntryPoint: Hashable, Sendable {
  case agent
}

@available(*, deprecated, renamed: "WorkspaceSelection")
public typealias AgentTuiSheetSelection = WorkspaceSelection
