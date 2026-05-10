import AppKit
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Session window flow contracts")
struct SessionWindowFlowTests {
  @Test("Session window token encodes the session identity")
  func sessionWindowTokenEncodingRoundTrips() throws {
    let token = SessionWindowToken(sessionID: "sess-alpha")
    let data = try JSONEncoder().encode(token)
    let decoded = try JSONDecoder().decode(SessionWindowToken.self, from: data)

    #expect(decoded == token)
    #expect(decoded.sessionID == "sess-alpha")
  }

  @Test("Session windows use dedicated scene identifiers")
  func sessionWindowsUseDedicatedSceneIdentifiers() {
    #expect(HarnessMonitorWindowID.openRecent == "open-recent")
    #expect(HarnessMonitorWindowID.sessionScene == "session")
    #expect(HarnessMonitorWindowID.sessionWindow("sess-alpha") == "session-sess-alpha")
  }

  @Test("Current schema includes session window restoration state")
  func currentSchemaIncludesSessionWindowRestorationState() {
    #expect(HarnessMonitorCurrentSchema.versionString == "9.0.0")
    #expect(
      HarnessMonitorSchemaV9.models.contains {
        String(describing: $0) == "CachedSessionWindowState"
      }
    )
  }

  @Test("Session window tabbing preference defaults to system")
  func sessionWindowTabbingPreferenceDefaultsToSystem() {
    #expect(SessionWindowTabbingPreference.defaultValue == .system)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: nil) == .system)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "system") == .system)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "always") == .always)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "never") == .never)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "unknown") == .system)
    #expect(
      SessionWindowTabbingPreference.storageKey == "harness.monitor.session-window.tabbing"
    )
  }

  @Test("Session tab opening honors app and system tabbing preferences")
  func sessionTabOpeningHonorsAppAndSystemPreferences() {
    #expect(
      !SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .never,
        userPreference: .always,
        targetIsFullScreen: true
      )
    )
    #expect(
      SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .always,
        userPreference: .manual,
        targetIsFullScreen: false
      )
    )
    #expect(
      !SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .system,
        userPreference: .manual,
        targetIsFullScreen: true
      )
    )
    #expect(
      SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .system,
        userPreference: .always,
        targetIsFullScreen: false
      )
    )
    #expect(
      !SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .system,
        userPreference: .inFullScreen,
        targetIsFullScreen: false
      )
    )
    #expect(
      SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .system,
        userPreference: .inFullScreen,
        targetIsFullScreen: true
      )
    )
  }

  @Test("Session routes expose stable sidebar order")
  func sessionRoutesExposeStableSidebarOrder() {
    #expect(
      SessionWindowRoute.allCases.map(\.rawValue)
        == ["overview", "agents", "tasks", "decisions", "timeline", "terminal"]
    )
    #expect(SessionWindowRoute.terminal.title == "Terminal/Runs")
    #expect(SessionWindowRoute.decisions.systemImage == "exclamationmark.bubble")
  }

  @Test("Session routes expose stable layout policy")
  func sessionRoutesExposeStableLayoutPolicy() {
    #expect(SessionWindowRoute.overview.layoutStyle == .sidebarDetail)
    #expect(SessionWindowRoute.timeline.layoutStyle == .sidebarDetail)
    #expect(SessionWindowRoute.agents.layoutStyle == .sidebarContentDetail)
    #expect(SessionWindowRoute.tasks.layoutStyle == .sidebarContentDetail)
    #expect(SessionWindowRoute.decisions.layoutStyle == .sidebarContentDetail)
    #expect(SessionWindowRoute.terminal.layoutStyle == .sidebarContentDetail)
  }

  @MainActor
  @Test("Session window state cache records session-scoped deep selections")
  func sessionWindowStateCacheRecordsDeepSelections() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")

    #expect(state.selection == .route(.overview))
    state.selectRoute(.timeline)
    state.selectDecision("decision-1")
    state.selectAgent("agent-1")
    state.selectTask("task-1")

    #expect(state.selection == .task(sessionID: "sess-alpha", taskID: "task-1"))
    #expect(state.selection.taskID == "task-1")
    #expect(
      state.navigationHistory.backStack == [
        .route(.overview),
        .route(.timeline),
        .decision(sessionID: "sess-alpha", decisionID: "decision-1"),
        .agent(sessionID: "sess-alpha", agentID: "agent-1"),
      ]
    )

    state.selectTask("task-1")
    #expect(state.navigationHistory.backStack.count == 4)
  }

  @MainActor
  @Test("Session sidebar selection uses native rows without composer focus")
  func sessionSidebarSelectionUsesNativeRowsWithoutComposerFocus() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")

    state.selectFromSidebar(.route(.timeline))
    #expect(state.selectionSource == .sidebar)
    #expect(state.agentComposerFocusRequestID == 0)

    state.selectFromSidebar(.agent(sessionID: "sess-alpha", agentID: "agent-a"))
    #expect(state.selection == .agent(sessionID: "sess-alpha", agentID: "agent-a"))
    #expect(state.selectionSource == .sidebar)
    #expect(state.agentComposerFocusRequestID == 0)

    state.selectFromSidebar(.task(sessionID: "sess-alpha", taskID: "task-a"))
    #expect(state.agentComposerFocusRequestID == 0)
  }

  @MainActor
  @Test("Session sidebar legacy pointer seam preserves native selection behavior")
  func sessionSidebarLegacyPointerSeamPreservesNativeSelectionBehavior() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")
    let pointerSelection = SessionSelection.agent(sessionID: "sess-alpha", agentID: "agent-a")

    state.markPointerSelectionIntent(for: pointerSelection)
    state.selectFromSidebar(pointerSelection)

    #expect(state.selection == pointerSelection)
    #expect(state.selectionSource == .sidebar)
    #expect(state.agentComposerFocusRequestID == 0)

    state.selectAgent("agent-b")
    #expect(state.selection == .agent(sessionID: "sess-alpha", agentID: "agent-b"))
    #expect(state.selectionSource == .programmatic)
    #expect(state.agentComposerFocusRequestID == 0)
  }

  @MainActor
  @Test("Transient nil sidebar updates do not reset routed session selection")
  func transientNilSidebarUpdatesDoNotResetSelection() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")
    let decisionSelection = SessionSelection.decision(
      sessionID: "sess-alpha",
      decisionID: "decision-a"
    )

    state.select(decisionSelection)
    state.selectFromSidebar(nil)

    #expect(state.selection == decisionSelection)
    #expect(state.selectionSource == .programmatic)
  }

  @MainActor
  @Test("Session sidebar legacy pointer intent does not alter native List selection")
  func sessionSidebarLegacyPointerIntentDoesNotAlterNativeListSelection() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")
    let pointerSelection = SessionSelection.agent(sessionID: "sess-alpha", agentID: "agent-a")

    state.markPointerSelectionIntent(for: pointerSelection)
    state.selectFromSidebar(.task(sessionID: "sess-alpha", taskID: "task-a"))

    #expect(state.selection == .task(sessionID: "sess-alpha", taskID: "task-a"))
    #expect(state.selectionSource == .sidebar)
    #expect(state.agentComposerFocusRequestID == 0)

    state.selectFromSidebar(pointerSelection)

    #expect(state.selection == pointerSelection)
    #expect(state.selectionSource == .sidebar)
    #expect(state.agentComposerFocusRequestID == 0)
  }

  @MainActor
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

  @MainActor
  @Test("Session decision bulk actions register undo reopen requests")
  func sessionDecisionBulkActionsRegisterUndoReopenRequests() {
    let bulkActions = SessionDecisionBulkActionState()
    let undoManager = UndoManager()

    bulkActions.recordDismissedBatch(["decision-a", "decision-b"], undoManager: undoManager)

    #expect(bulkActions.lastDismissedBatch == ["decision-a", "decision-b"])
    #expect(undoManager.canUndo)
    undoManager.undo()
    #expect(bulkActions.reopenRequestedBatch == ["decision-a", "decision-b"])
  }

  @MainActor
  @Test("Session decision bulk actions expose expiring undo toast")
  func sessionDecisionBulkActionsExposeExpiringUndoToast() throws {
    let bulkActions = SessionDecisionBulkActionState()
    let now = Date(timeIntervalSinceReferenceDate: 100)

    bulkActions.recordDismissedBatch(["decision-a", "decision-b"], undoManager: nil, now: now)

    let toast = try #require(bulkActions.undoToast)
    #expect(toast.count == 2)
    #expect(toast.expiresAt == now.addingTimeInterval(8))
    #expect(toast.dismissedCopy == "Dismissed 2 decisions")
    #expect(
      toast.accessibilityCopy
        == "Dismissed 2 decisions. Undo available. Closing window confirms dismissal."
    )
    bulkActions.clearExpiredUndoToast(now: now.addingTimeInterval(7.9))
    #expect(bulkActions.undoToast != nil)
    bulkActions.clearExpiredUndoToast(now: now.addingTimeInterval(8))
    #expect(bulkActions.undoToast == nil)

    bulkActions.recordDismissedBatch(["decision-c"], undoManager: nil, now: now)
    bulkActions.requestUndoToastReopen()

    #expect(bulkActions.reopenRequestedBatch == ["decision-c"])
    #expect(bulkActions.undoToast == nil)
  }
}
