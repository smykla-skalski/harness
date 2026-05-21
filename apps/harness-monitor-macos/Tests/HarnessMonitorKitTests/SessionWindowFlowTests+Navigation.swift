import AppKit
import Foundation
import SwiftUI
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

@Suite("Session window native tabbing")
struct SessionWindowNativeTabbingTests {
  @MainActor
  @Test("Shared tab merge coordinator combines dashboard and session windows as native tabs")
  func sharedTabMergeCoordinatorCombinesDashboardAndSessionWindows() async {
    let targetWindow = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 480, height: 320),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    targetWindow.toolbar = NSToolbar(identifier: "session-window")

    let dashboardWindow = NSWindow(
      contentRect: .init(x: 32, y: 32, width: 480, height: 320),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    dashboardWindow.toolbar = NSToolbar(identifier: "dashboard-window")

    defer {
      dashboardWindow.orderOut(nil)
      targetWindow.orderOut(nil)
    }

    SessionWindowTabbingSupport.prepareWindowForTabbing(targetWindow, preference: .always)
    SessionWindowTabbingSupport.prepareWindowForTabbing(dashboardWindow, preference: .always)

    targetWindow.orderFront(nil)
    dashboardWindow.makeKeyAndOrderFront(nil)

    await SessionWindowTabMergeCoordinator.mergeNewestTabbedWindowIfNeeded(
      into: targetWindow,
      preference: .always
    )

    #expect(targetWindow.tabGroup != nil)
    #expect(targetWindow.tabGroup === dashboardWindow.tabGroup)
  }

  @MainActor
  @Test(
    "Shared tab merge coordinator waits for a new third window instead of reusing an existing tab"
  )
  func sharedTabMergeCoordinatorWaitsForThirdWindowToBecomeTabReady() async throws {
    let targetWindow = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 480, height: 320),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    targetWindow.toolbar = NSToolbar(identifier: "session-window")

    let existingPeerWindow = NSWindow(
      contentRect: .init(x: 32, y: 32, width: 480, height: 320),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    existingPeerWindow.toolbar = NSToolbar(identifier: "peer-window")

    let lateWindow = NSWindow(
      contentRect: .init(x: 64, y: 64, width: 480, height: 320),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )

    defer {
      lateWindow.orderOut(nil)
      existingPeerWindow.orderOut(nil)
      targetWindow.orderOut(nil)
    }

    SessionWindowTabbingSupport.prepareWindowForTabbing(targetWindow, preference: .always)
    SessionWindowTabbingSupport.prepareWindowForTabbing(existingPeerWindow, preference: .always)

    targetWindow.orderFront(nil)
    existingPeerWindow.makeKeyAndOrderFront(nil)
    targetWindow.addTabbedWindow(existingPeerWindow, ordered: .above)
    lateWindow.orderFront(nil)
    for _ in 0..<20 {
      if targetWindow.tabbedWindows?.contains(where: { $0 === existingPeerWindow }) == true
        || targetWindow.tabGroup === existingPeerWindow.tabGroup
      {
        break
      }
      await Task.yield()
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      targetWindow.tabbedWindows?.contains(where: { $0 === existingPeerWindow }) == true
        || targetWindow.tabGroup === existingPeerWindow.tabGroup
    )

    let mergeTask = Task { @MainActor in
      await SessionWindowTabMergeCoordinator.mergeNewestTabbedWindowIfNeeded(
        into: targetWindow,
        preference: .always
      )
    }

    try await Task.sleep(for: .milliseconds(80))
    lateWindow.toolbar = NSToolbar(identifier: "late-window")
    SessionWindowTabbingSupport.prepareWindowForTabbing(lateWindow, preference: .always)

    await mergeTask.value

    #expect(targetWindow.tabGroup != nil)
    #expect(targetWindow.tabGroup === existingPeerWindow.tabGroup)
    #expect(targetWindow.tabGroup === lateWindow.tabGroup)
    #expect(targetWindow.tabGroup?.windows.count == 3)
  }
}
