import Observation

public enum SessionSelection: Hashable, Sendable {
  case route(SessionWindowRoute)
  case agent(sessionID: String, agentID: String)
  case decision(sessionID: String, decisionID: String)
  case task(sessionID: String, taskID: String)

  public var route: SessionWindowRoute? {
    guard case .route(let route) = self else { return nil }
    return route
  }

  public var agentID: String? {
    guard case .agent(_, let agentID) = self else { return nil }
    return agentID
  }

  public var decisionID: String? {
    guard case .decision(_, let decisionID) = self else { return nil }
    return decisionID
  }

  public var taskID: String? {
    guard case .task(_, let taskID) = self else { return nil }
    return taskID
  }
}

@MainActor
@Observable
public final class SessionWindowStateCache {
  public let sessionID: String
  public var selection: SessionSelection
  public var navigationHistory = SessionWindowNavigationHistory()
  public var attention = SessionAttentionState()

  public init(
    sessionID: String,
    selection: SessionSelection = .route(.overview)
  ) {
    self.sessionID = sessionID
    self.selection = selection
  }

  public func selectRoute(_ route: SessionWindowRoute) {
    updateSelection(.route(route))
  }

  public func selectAgent(_ agentID: String) {
    updateSelection(.agent(sessionID: sessionID, agentID: agentID))
  }

  public func selectDecision(_ decisionID: String) {
    updateSelection(.decision(sessionID: sessionID, decisionID: decisionID))
  }

  public func selectTask(_ taskID: String) {
    updateSelection(.task(sessionID: sessionID, taskID: taskID))
  }

  private func updateSelection(_ nextSelection: SessionSelection) {
    guard selection != nextSelection else { return }
    navigationHistory.record(selection)
    selection = nextSelection
  }
}

@MainActor
@Observable
public final class SessionWindowNavigationHistory {
  public private(set) var backStack: [SessionSelection] = []
  public private(set) var forwardStack: [SessionSelection] = []

  public init() {}

  public func record(_ selection: SessionSelection) {
    backStack.append(selection)
    forwardStack.removeAll()
  }
}

@MainActor
@Observable
public final class SessionAttentionState {
  public var pendingDecisionCount = 0

  public init() {}
}
