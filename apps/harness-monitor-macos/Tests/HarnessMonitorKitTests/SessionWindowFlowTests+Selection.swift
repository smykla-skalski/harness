import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
extension SessionWindowFlowTests {
  @Test("Shared tabbing preparation keeps dashboard and session windows eligible for one tab group")
  func sharedTabbingPreparationUsesOneIdentifier() {
    let dashboardWindow = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let sessionWindow = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )

    SessionWindowTabbingSupport.prepareWindowForTabbing(dashboardWindow, preference: .always)
    SessionWindowTabbingSupport.prepareWindowForTabbing(sessionWindow, preference: .always)

    #expect(dashboardWindow.tabbingIdentifier == SessionWindowTabbingSupport.tabbingIdentifier)
    #expect(sessionWindow.tabbingIdentifier == SessionWindowTabbingSupport.tabbingIdentifier)
    #expect(dashboardWindow.tabbingMode == .preferred)
    #expect(sessionWindow.tabbingMode == .preferred)
  }

  @Test("Session routes expose stable sidebar order")
  func sessionRoutesExposeStableSidebarOrder() {
    #expect(
      SessionWindowRoute.allCases.map(\.rawValue)
        == ["overview", "agents", "tasks", "policyCanvas", "decisions", "timeline"]
    )
    #expect(SessionWindowRoute.agents.title == "Agents")
    #expect(SessionWindowRoute.agents.systemImage == "person.2")
    #expect(SessionWindowRoute.policyCanvas.title == "Policy")
    #expect(
      SessionWindowRoute.policyCanvas.systemImage
        == "point.3.connected.trianglepath.dotted"
    )
    #expect(SessionWindowRoute.decisions.systemImage == "exclamationmark.bubble")
  }

  @Test("Dashboard routes expose stable sidebar order")
  func dashboardRoutesExposeStableSidebarOrder() {
    #expect(
      DashboardWindowRoute.allCases.map(\.rawValue)
        == ["taskBoard", "policyCanvas", "notifications", "diagnostics", "dependencies"]
    )
    #expect(DashboardWindowRoute.taskBoard.title == "Board")
    #expect(DashboardWindowRoute.policyCanvas.title == "Policy")
    #expect(
      DashboardWindowRoute.policyCanvas.systemImage
        == SessionWindowRoute.policyCanvas.systemImage
    )
    #expect(DashboardWindowRoute.notifications.title == "Notifications")
    #expect(DashboardWindowRoute.notifications.systemImage == "bell.badge")
    #expect(DashboardWindowRoute.diagnostics.title == "Diagnostics")
    #expect(DashboardWindowRoute.diagnostics.systemImage == "stethoscope")
    #expect(DashboardWindowRoute.reviews.title == "Reviews")
    #expect(DashboardWindowRoute.reviews.systemImage == "shippingbox.circle")
  }

  @Test("Session routes expose stable layout policy")
  func sessionRoutesExposeStableLayoutPolicy() {
    #expect(SessionWindowRoute.overview.layoutStyle == .sidebarDetail)
    #expect(SessionWindowRoute.timeline.layoutStyle == .sidebarDetail)
    #expect(SessionWindowRoute.agents.layoutStyle == .sidebarContentDetail)
    #expect(SessionWindowRoute.tasks.layoutStyle == .sidebarContentDetail)
    #expect(SessionWindowRoute.decisions.layoutStyle == .sidebarContentDetail)
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

    state.selectFromSidebar(.route(.agents))
    #expect(state.selection == .route(.agents))
    #expect(state.selectionSource == .sidebar)
    #expect(state.agentComposerFocusRequestID == 0)

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
  @Test("Route-level agent selection does not replace the agents route selection")
  func routeLevelAgentSelectionDoesNotReplaceTheAgentsRouteSelection() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")

    state.selectFromSidebar(.route(.agents))
    state.setRouteAgentID("agent-a")

    #expect(state.selection == .route(.agents))
    #expect(state.sectionState.agentID == "agent-a")
    #expect(state.selectionSource == .sidebar)
  }

  @MainActor
  @Test("Route-level task selection does not replace the tasks route selection")
  func routeLevelTaskSelectionDoesNotReplaceTheTasksRouteSelection() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")

    state.selectFromSidebar(.route(.tasks))
    state.setRouteTaskID("task-a")

    #expect(state.selection == .route(.tasks))
    #expect(state.sectionState.taskID == "task-a")
    #expect(state.selectionSource == .sidebar)
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
}
