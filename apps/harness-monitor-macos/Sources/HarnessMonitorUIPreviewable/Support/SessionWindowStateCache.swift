import HarnessMonitorKit
import Observation

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
  public var sessionID: String

  public init(
    kind: SessionCreateKind,
    title: String = "",
    prompt: String = "",
    runtime: String = AgentTuiRuntime.codex.rawValue,
    sessionID: String
  ) {
    self.kind = kind
    self.title = title
    self.prompt = prompt
    self.runtime = runtime
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

public enum SessionSelectionSource: Hashable, Sendable {
  case programmatic
  case keyboard
  case pointer
}

public enum SessionSelectedDecisionVisibility: Equatable, Sendable {
  case none
  case visible
  case hidden
  case missing
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
  public var decisionFilters = SessionDecisionFilterState()
  public var decisionBulkActions = SessionDecisionBulkActionState()
  public var navigationHistory = SessionWindowNavigationHistory()
  public var attention = SessionAttentionState()
  public var lastTaskDecisionLink: SessionTaskDecisionLink?
  public private(set) var selectionSource: SessionSelectionSource = .programmatic
  public private(set) var agentComposerFocusRequestID = 0
  private var pendingSelectionSource: (selection: SessionSelection, source: SessionSelectionSource)?

  public init(sessionID: String, selection: SessionSelection = .route(.overview)) {
    self.sessionID = sessionID
    self.selection = selection
  }

  public func selectRoute(_ route: SessionWindowRoute) {
    updateSelection(.route(route), source: .programmatic)
  }

  public func selectAgent(_ agentID: String) {
    updateSelection(.agent(sessionID: sessionID, agentID: agentID), source: .programmatic)
  }

  public func selectDecision(_ decisionID: String) {
    updateSelection(.decision(sessionID: sessionID, decisionID: decisionID), source: .programmatic)
  }

  public func selectTask(_ taskID: String) {
    updateSelection(.task(sessionID: sessionID, taskID: taskID), source: .programmatic)
  }

  public func selectCreate(_ kind: SessionCreateKind) {
    let existing = sectionState.createDrafts[kind]
    let draft = existing ?? SessionCreateDraft(kind: kind, sessionID: sessionID)
    updateSelection(.create(draft), source: .programmatic)
  }

  public func select(_ selection: SessionSelection) {
    updateSelection(selection, source: .programmatic)
  }

  public func selectFromSidebar(_ selection: SessionSelection?) {
    let nextSelection = selection ?? .route(.overview)
    let source: SessionSelectionSource
    if pendingSelectionSource?.selection == nextSelection {
      source = pendingSelectionSource?.source ?? .keyboard
    } else {
      source = .keyboard
    }
    pendingSelectionSource = nil
    updateSelection(nextSelection, source: source)
  }

  public func markPointerSelectionIntent(for selection: SessionSelection) {
    pendingSelectionSource = (selection, .pointer)
  }

  public func updateCreateDraft(_ draft: SessionCreateDraft) {
    sectionState.createDrafts[draft.kind] = draft
    guard selection.createDraft?.kind == draft.kind else { return }
    selection = .create(draft)
  }

  public func cancelCreateDraft(_ kind: SessionCreateKind) {
    sectionState.createDrafts[kind] = nil
    updateSelection(
      .route(kind.route),
      source: .programmatic,
      rememberCurrentSelection: false,
      recordHistory: false
    )
  }

  public func navigateBack() {
    guard let previous = navigationHistory.popBack(current: selection) else { return }
    selection = previous
  }

  public func navigateForward() {
    guard let next = navigationHistory.popForward(current: selection) else { return }
    selection = next
  }

  public func selectedDecision(in decisions: [Decision]) -> Decision? {
    guard let decisionID = selection.decisionID else {
      return nil
    }
    return decisions.first { $0.id == decisionID }
  }

  public func selectedDecisionVisibility(
    allDecisionIDs: Set<String>,
    visibleDecisionIDs: Set<String>
  ) -> SessionSelectedDecisionVisibility {
    guard let decisionID = selection.decisionID else {
      return .none
    }
    if visibleDecisionIDs.contains(decisionID) {
      return .visible
    }
    if allDecisionIDs.contains(decisionID) {
      return .hidden
    }
    return .missing
  }

  private func updateSelection(
    _ nextSelection: SessionSelection,
    source: SessionSelectionSource,
    rememberCurrentSelection: Bool = true,
    recordHistory: Bool = true
  ) {
    if selection != nextSelection {
      if rememberCurrentSelection {
        sectionState.remember(selection)
      }
      if recordHistory {
        navigationHistory.record(selection)
      }
      selection = nextSelection
    }
    selectionSource = source
    if case .agent = nextSelection, source == .keyboard {
      agentComposerFocusRequestID += 1
    }
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

  public func hasDraft(_ kind: SessionCreateKind) -> Bool {
    guard let draft = createDrafts[kind] else { return false }
    return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
