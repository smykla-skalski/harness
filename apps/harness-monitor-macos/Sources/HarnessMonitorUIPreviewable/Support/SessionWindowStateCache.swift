import Foundation
import HarnessMonitorKit
import Observation

public enum SessionCreateKind: String, Codable, Hashable, Sendable {
  case agent
  case task
  case decision
}

public struct SessionCreateDraft: Codable, Hashable, Sendable {
  public var kind: SessionCreateKind
  public var title: String
  public var sessionID: String

  public init(
    kind: SessionCreateKind,
    title: String = "",
    sessionID: String
  ) {
    self.kind = kind
    self.title = title
    self.sessionID = sessionID
  }
}

public enum SessionSelection: Hashable, Sendable {
  case route(SessionWindowRoute)
  case agent(sessionID: String, agentID: String)
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

@MainActor
@Observable
public final class SessionWindowStateCache {
  public let sessionID: String
  public var selection: SessionSelection
  public var sidebarOrdering = SessionSidebarOrderingState()
  public var sidebarSelection = SessionSidebarSelectionState()
  public var sectionState = SessionWindowSectionState()
  public var decisionRuntime = SessionDecisionRuntime()
  public var navigationHistory = SessionWindowNavigationHistory()
  public var attention = SessionAttentionState()
  public var lastTaskDecisionLink: SessionTaskDecisionLink?

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

  public func selectCreate(_ kind: SessionCreateKind) {
    let existing = sectionState.createDrafts[kind]
    let draft = existing ?? SessionCreateDraft(kind: kind, sessionID: sessionID)
    updateSelection(.create(draft))
  }

  public func select(_ selection: SessionSelection) {
    updateSelection(selection)
  }

  public func updateCreateDraft(_ draft: SessionCreateDraft) {
    sectionState.createDrafts[draft.kind] = draft
    guard selection.createDraft?.kind == draft.kind else { return }
    selection = .create(draft)
  }

  public func navigateBack() {
    guard let previous = navigationHistory.popBack(current: selection) else { return }
    selection = previous
  }

  public func navigateForward() {
    guard let next = navigationHistory.popForward(current: selection) else { return }
    selection = next
  }

  private func updateSelection(_ nextSelection: SessionSelection) {
    guard selection != nextSelection else { return }
    sectionState.remember(selection)
    navigationHistory.record(selection)
    selection = nextSelection
  }
}

public struct SessionTaskDecisionLink: Equatable, Sendable {
  public let sessionID: String
  public let taskID: String
  public let decisionID: String

  public init(sessionID: String, taskID: String, decisionID: String) {
    self.sessionID = sessionID
    self.taskID = taskID
    self.decisionID = decisionID
  }
}

@MainActor
@Observable
public final class SessionSidebarSelectionState {
  public var isDecisionMultiSelectEnabled = false
  public var selectedDecisionIDs: Set<String> = []

  public init() {}

  public func toggleDecisionMultiSelect() {
    isDecisionMultiSelectEnabled.toggle()
    if !isDecisionMultiSelectEnabled {
      selectedDecisionIDs.removeAll()
    }
  }

  public func toggleDecision(_ decisionID: String) {
    if selectedDecisionIDs.contains(decisionID) {
      selectedDecisionIDs.remove(decisionID)
    } else {
      selectedDecisionIDs.insert(decisionID)
    }
  }

  public func pruneDecisionSelection(to visibleDecisionIDs: Set<String>) {
    selectedDecisionIDs.formIntersection(visibleDecisionIDs)
  }
}

@MainActor
@Observable
public final class SessionWindowSectionState {
  public var routeSelection: SessionWindowRoute = .overview
  public var agentID: String?
  public var decisionID: String?
  public var taskID: String?
  public var createDrafts: [SessionCreateKind: SessionCreateDraft] = [:]

  public init() {}

  public func remember(_ selection: SessionSelection) {
    switch selection {
    case .route(let route):
      routeSelection = route
    case .agent(_, let agentID):
      self.agentID = agentID
    case .decision(_, let decisionID):
      self.decisionID = decisionID
    case .task(_, let taskID):
      self.taskID = taskID
    case .create(let draft):
      createDrafts[draft.kind] = draft
    }
  }
}

@MainActor
@Observable
public final class SessionSidebarOrderingState {
  public var agentIDs: [String] = []

  public init() {}

  public func orderedAgents(_ agents: [AgentRegistration]) -> [AgentRegistration] {
    reconcileAgentIDs(with: agents.map(\.agentId))
    let order = Dictionary(uniqueKeysWithValues: agentIDs.enumerated().map { ($1, $0) })
    return agents.sorted { left, right in
      (order[left.agentId] ?? Int.max, left.agentId)
        < (order[right.agentId] ?? Int.max, right.agentId)
    }
  }

  public func moveAgent(
    _ agentID: String,
    before targetID: String?,
    undoManager: UndoManager?
  ) {
    let previous = agentIDs
    applyAgentMove(agentID, before: targetID)
    guard previous != agentIDs else { return }
    undoManager?.registerUndo(withTarget: self) { target in
      target.agentIDs = previous
    }
    undoManager?.setActionName("Move Agent")
  }

  private func reconcileAgentIDs(with liveIDs: [String]) {
    let liveSet = Set(liveIDs)
    let retained = agentIDs.filter { liveSet.contains($0) }
    let retainedSet = Set(retained)
    agentIDs = retained + liveIDs.filter { !retainedSet.contains($0) }
  }

  private func applyAgentMove(_ agentID: String, before targetID: String?) {
    agentIDs.removeAll { $0 == agentID }
    guard let targetID, let targetIndex = agentIDs.firstIndex(of: targetID) else {
      agentIDs.append(agentID)
      return
    }
    agentIDs.insert(agentID, at: targetIndex)
  }
}

@MainActor
@Observable
public final class SessionWindowNavigationHistory {
  public private(set) var backStack: [SessionSelection] = []
  public private(set) var forwardStack: [SessionSelection] = []

  public init() {}

  public var canGoBack: Bool { !backStack.isEmpty }
  public var canGoForward: Bool { !forwardStack.isEmpty }

  public func record(_ selection: SessionSelection) {
    backStack.append(selection)
    forwardStack.removeAll()
  }

  public func popBack(current: SessionSelection) -> SessionSelection? {
    guard let previous = backStack.popLast() else { return nil }
    forwardStack.append(current)
    return previous
  }

  public func popForward(current: SessionSelection) -> SessionSelection? {
    guard let next = forwardStack.popLast() else { return nil }
    backStack.append(current)
    return next
  }
}

@MainActor
@Observable
public final class SessionAttentionState {
  public var pendingDecisionCount = 0

  public init() {}
}
