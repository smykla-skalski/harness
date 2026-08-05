import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
extension SessionWindowFlowTests {
  @Test("Session window navigation history is isolated per window cache")
  func sessionWindowNavigationHistoryIsIsolatedPerWindowCache() {
    let alpha = SessionWindowStateCache(sessionID: "sess-alpha")
    let beta = SessionWindowStateCache(sessionID: "sess-beta")

    alpha.selectRoute(.timeline)
    alpha.selectAgent("agent-alpha")
    beta.selectRoute(.decisions)

    alpha.navigateBack()

    #expect(alpha.selection == .route(.timeline))
    #expect(beta.selection == .route(.decisions))
    #expect(beta.navigationHistory.backStack == [.route(.overview)])

    beta.navigateBack()

    #expect(alpha.selection == .route(.timeline))
    #expect(beta.selection == .route(.overview))
  }

  @MainActor
  @Test("Session history navigation resets selection source and preserves forward state")
  func sessionHistoryNavigationResetsSelectionSourceAndPreservesForwardState() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")

    state.selectFromSidebar(.route(.timeline))
    state.selectFromSidebar(.decision(sessionID: "sess-alpha", decisionID: "decision-a"))

    #expect(state.selectionSource == .sidebar)
    #expect(state.navigationHistory.canGoBack)
    #expect(!state.navigationHistory.canGoForward)

    state.navigateBack()

    #expect(state.selection == .route(.timeline))
    #expect(state.selectionSource == .programmatic)
    #expect(state.navigationHistory.canGoBack)
    #expect(state.navigationHistory.canGoForward)
    #expect(
      state.navigationHistory.forwardStack
        == [.decision(sessionID: "sess-alpha", decisionID: "decision-a")]
    )

    state.navigateForward()

    #expect(state.selection == .decision(sessionID: "sess-alpha", decisionID: "decision-a"))
    #expect(state.selectionSource == .programmatic)
    #expect(state.navigationHistory.canGoBack)
    #expect(!state.navigationHistory.canGoForward)
  }

  @MainActor
  @Test("Session window cache preserves create drafts and section selections")
  func sessionWindowCachePreservesCreateDraftsAndSectionSelections() throws {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")

    state.selectAgent("agent-1")
    state.selectCreate(.agent)
    var draft = try #require(state.selection.createDraft)
    draft.title = "Review worker"
    state.updateCreateDraft(draft)
    state.selectTask("task-1")
    state.selectCreate(.agent)

    #expect(state.sectionState.agentID == "agent-1")
    #expect(state.sectionState.taskID == "task-1")
    #expect(state.selection.createDraft?.title == "Review worker")
    #expect(state.selection.createDraft?.sessionID == "sess-alpha")
  }

  @MainActor
  @Test("Session sidebar ordering registers undoable agent moves")
  func sessionSidebarOrderingRegistersUndoableAgentMoves() {
    let ordering = SessionSidebarOrderingState()
    ordering.agentIDs = ["agent-a", "agent-b", "agent-c"]
    let undoManager = UndoManager()

    ordering.moveAgent("agent-c", before: "agent-a", undoManager: undoManager)

    #expect(ordering.agentIDs == ["agent-c", "agent-a", "agent-b"])
    #expect(undoManager.canUndo)
    undoManager.undo()
    #expect(ordering.agentIDs == ["agent-a", "agent-b", "agent-c"])
  }

  @MainActor
  @Test("Session sidebar decision multi-select prunes to visible rows")
  func sessionSidebarDecisionMultiSelectPrunesToVisibleRows() {
    let selection = SessionSidebarSelectionState()

    selection.toggleDecisionMultiSelect()
    selection.toggleDecision("decision-a")
    selection.toggleDecision("decision-b")
    selection.prune(kind: .decision, visibleIDs: ["decision-b", "decision-c"])

    #expect(selection.isDecisionMultiSelectEnabled)
    #expect(selection.selectedDecisionIDs == ["decision-b"])
    selection.toggleDecisionMultiSelect()
    #expect(selection.selectedDecisionIDs.isEmpty)
  }

  @MainActor
  @Test("Session decision filters match query severity and scope")
  func sessionDecisionFiltersMatchQuerySeverityAndScope() {
    let filters = SessionDecisionFilterState()
    let decision = Decision(
      id: "decision-a",
      severity: .critical,
      ruleID: "stuck-agent",
      sessionID: "sess-alpha",
      agentID: "agent-a",
      taskID: "task-a",
      summary: "Agent stopped responding",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )

    filters.query = "responding"
    #expect(filters.matches(decision))
    filters.scope = .ruleID
    #expect(!filters.matches(decision))
    filters.query = "stuck-agent"
    #expect(filters.matches(decision))
    filters.scope = .agent
    #expect(!filters.matches(decision))
    filters.query = "agent-a"
    #expect(filters.matches(decision))
    filters.severities = [.warn]
    #expect(!filters.matches(decision))
    filters.severities = [.critical]
    #expect(filters.matches(decision))
    filters.clear()
    #expect(filters.scope == .summary)
    #expect(filters.matches(decision))
  }

}
