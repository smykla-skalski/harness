import HarnessMonitorKit
import Observation

#if canImport(AppKit)
  import AppKit
#endif

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
  private var pendingSourceOverride: SessionSelectionSource?

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
    let source = pendingSourceOverride ?? Self.detectSidebarSelectionSource()
    pendingSourceOverride = nil
    updateSelection(nextSelection, source: source)
  }

  /// Test-only seam: pin the next `selectFromSidebar` source to `.pointer` so
  /// unit tests can simulate a click without an `NSEvent`. Real UI never calls
  /// this — the View layer relies on `NSApp.currentEvent` detection inside
  /// `selectFromSidebar`. Kept named for back-compat with existing tests; the
  /// `selection` argument is ignored.
  public func markPointerSelectionIntent(for selection: SessionSelection) {
    _ = selection
    pendingSourceOverride = .pointer
  }

  private static func detectSidebarSelectionSource() -> SessionSelectionSource {
    #if canImport(AppKit)
      if let event = NSApp.currentEvent {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
          .otherMouseDown, .otherMouseUp:
          return .pointer
        default:
          break
        }
      }
    #endif
    return .keyboard
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
