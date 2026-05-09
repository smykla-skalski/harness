import HarnessMonitorKit

public enum SessionCreateKind: String, Codable, Hashable, Sendable {
  case agent
  case task
  case decision

  public var route: SessionWindowRoute {
    switch self {
    case .agent: .agents
    case .task: .tasks
    case .decision: .decisions
    }
  }
}

public struct SessionCreateDraft: Codable, Hashable, Sendable {
  public var kind: SessionCreateKind
  public var title: String
  public var prompt: String
  public var runtime: String
  public var taskSeverityRawValue: String?
  public var sessionID: String

  public init(
    kind: SessionCreateKind,
    title: String = "",
    prompt: String = "",
    runtime: String = AgentTuiRuntime.codex.rawValue,
    taskSeverity: TaskSeverity = .medium,
    sessionID: String
  ) {
    self.kind = kind
    self.title = title
    self.prompt = prompt
    self.runtime = runtime
    taskSeverityRawValue = taskSeverity.rawValue
    self.sessionID = sessionID
  }

  public var taskSeverity: TaskSeverity {
    get {
      taskSeverityRawValue.flatMap(TaskSeverity.init(rawValue:)) ?? .medium
    }
    set {
      taskSeverityRawValue = newValue.rawValue
    }
  }
}

public enum SessionSelection: Hashable, Sendable {
  case route(SessionWindowRoute)
  case agent(sessionID: String, agentID: String)
  case codexRun(sessionID: String, runID: String)
  case decision(sessionID: String, decisionID: String)
  case task(sessionID: String, taskID: String)
  case create(SessionCreateDraft)

  public var route: SessionWindowRoute? {
    guard case .route(let route) = self else { return nil }
    return route
  }

  public var agentID: String? {
    guard case .agent(_, let agentID) = self else { return nil }
    return agentID
  }

  public var codexRunID: String? {
    guard case .codexRun(_, let runID) = self else { return nil }
    return runID
  }

  public var decisionID: String? {
    guard case .decision(_, let decisionID) = self else { return nil }
    return decisionID
  }

  public var taskID: String? {
    guard case .task(_, let taskID) = self else { return nil }
    return taskID
  }

  public var createDraft: SessionCreateDraft? {
    guard case .create(let draft) = self else { return nil }
    return draft
  }
}

public enum SessionSelectionSource: Hashable, Sendable {
  case programmatic
  case sidebar
  case keyboard
  case pointer
}

public enum SessionSelectedDecisionVisibility: Equatable, Sendable {
  case none
  case visible
  case hidden
  case missing
}
