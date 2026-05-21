import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  func sessionWindowSelectionObservers<Content: View>(
    _ content: Content
  ) -> some View {
    content
      .onChange(of: stateCache.selection) { _, newSelection in
        history.recordSessionSelection(
          sessionID: token.sessionID,
          selection: newSelection
        )
        syncPersistedStorage(from: newSelection)
        reconcileInspectorVisibility(
          visibleBinding: inspectorVisibleBinding,
          preferredBinding: inspectorPreferredBinding
        )
        detailRenderedSelection = newSelection
        contentRenderedRoute = route(for: newSelection)
        if case .create(let draft) = newSelection, draft.kind == .agent {
          commitContentColumnWidth(SessionContentDetailSplitLayout.defaultContentWidth)
        }
      }
      .onChange(of: stateCache.sectionState.decisionID) { _, newDecisionID in
        guard HarnessMonitorPerfIsolation.allowsSceneRestorationWrites else { return }
        guard case .route(.decisions) = stateCache.selection else { return }
        let storedDecisionID = newDecisionID ?? ""
        guard persistedDecisionID != storedDecisionID else { return }
        HarnessMonitorPerfTrace.recordScenarioEvent(
          component: "perf.scene-storage",
          event: "decision-id.write"
        )
        persistedDecisionID = storedDecisionID
      }
      .onChange(of: renderedRoute) { _, newRoute in
        guard newRoute.layoutStyle == .sidebarDetail else { return }
        detailColumnWidth = 0
      }
      .onChange(of: allSessionDecisionIDsInOrderCache) { _, _ in
        reconcileInspectorVisibility(
          visibleBinding: inspectorVisibleBinding,
          preferredBinding: inspectorPreferredBinding
        )
      }
  }

  @MainActor
  func applyPendingHistoryRestoreIfNeeded() async {
    guard let request = history.pendingSessionRestoreRequest else {
      return
    }
    guard request.sessionID == token.sessionID else {
      return
    }
    guard request.requestID != handledHistoryRestoreRequestID else {
      return
    }
    handledHistoryRestoreRequestID = request.requestID
    if stateCache.selection != request.selection {
      stateCache.restoreNavigationSelection(request.selection)
    }
    await Task.yield()
    history.finishSessionRestoreRequest(
      request.requestID,
      sessionID: token.sessionID
    )
  }

  func sessionWindowDecisionFilterPersistence<Content: View>(
    _ content: Content
  ) -> some View {
    content
      .onChange(of: stateCache.decisionFilters.query) { _, newValue in
        guard HarnessMonitorPerfIsolation.allowsSceneRestorationWrites else { return }
        guard persistedDecisionQuery != newValue else { return }
        HarnessMonitorPerfTrace.recordScenarioEvent(
          component: "perf.scene-storage",
          event: "decision-query.write",
          details: ["characters": String(newValue.count)]
        )
        persistedDecisionQuery = newValue
      }
  }

  @MainActor
  func applyPendingSessionRouteIfNeeded() async {
    let pendingRequest = store.pendingSessionRouteRequestSnapshot
    guard let request = store.consumePendingSessionRouteRequest(forSessionID: token.sessionID)
    else {
      if let pendingRequest {
        HarnessMonitorUITestTrace.record(
          component: "session.window.route",
          event: "request.unmatched",
          details: [
            "window_session_id": token.sessionID,
            "selection": routeSelectionTraceLabel(for: pendingRequest.selection),
            "target_session_id": pendingRequest.selection.sessionID ?? pendingRequest
              .createSessionID
              ?? "nil",
            "request_id": String(store.pendingSessionRouteRequestID),
          ]
        )
      }
      return
    }
    HarnessMonitorUITestTrace.record(
      component: "session.window.route",
      event: "request.applied",
      details: [
        "window_session_id": token.sessionID,
        "selection": routeSelectionTraceLabel(for: request.selection),
        "target_session_id": request.selection.sessionID ?? request.createSessionID ?? "nil",
        "request_id": String(store.pendingSessionRouteRequestID),
      ]
    )
    if request.resetDecisionFilters {
      stateCache.decisionFilters.clear()
      clearPersistedDecisionQueryIfNeeded()
    }
    switch request.selection {
    case .create:
      stateCache.selectCreate(routeCreateKind(for: request))
    case .decisions:
      stateCache.selectRoute(.decisions)
    case .decision(_, let decisionID):
      stateCache.selectDecision(decisionID)
    case .terminal(_, let terminalID):
      stateCache.selectAgent(terminalID)
    case .codex(_, let runID):
      stateCache.select(.codexRun(sessionID: token.sessionID, runID: runID))
    case .agent(_, let agentID):
      stateCache.selectAgent(agentID)
    case .task(_, let taskID):
      stateCache.selectTask(taskID)
    }
  }

  func routeCreateKind(
    for request: HarnessMonitorStore.PendingSessionRouteRequest
  ) -> SessionCreateKind {
    switch request.createEntryPoint {
    case .agent, nil:
      return .agent
    case .task:
      return .task
    case .decision:
      return .decision
    }
  }

  func routeSelectionTraceLabel(for selection: SessionRouteSelection) -> String {
    switch selection {
    case .create:
      return "create"
    case .decisions:
      return "decisions"
    case .decision(_, let decisionID):
      return "decision:\(decisionID)"
    case .terminal(_, let terminalID):
      return "terminal->agent:\(terminalID)"
    case .codex(_, let runID):
      return "codex:\(runID)"
    case .agent(_, let agentID):
      return "agent:\(agentID)"
    case .task(_, let taskID):
      return "task:\(taskID)"
    }
  }

  func requestPrimaryContentAccessibilityFocus() {
    guard !isUnknownSession else { return }
    primaryContentAccessibilityFocused = true
    let title = summary?.displayTitle ?? "Session"
    AccessibilityNotification.Announcement("\(title) session window opened").post()
  }
}
