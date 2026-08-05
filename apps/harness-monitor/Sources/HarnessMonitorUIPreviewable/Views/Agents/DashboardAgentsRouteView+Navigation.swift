import HarnessMonitorKit

extension DashboardAgentsRouteView {
  func applyPendingHistoryRestoreIfNeeded() {
    guard let request = history.pendingDashboardAgentsRestoreRequest else { return }
    if case .createTerminal(let sessionID) = request.target {
      switch DashboardTerminalCreationNavigationResolution.resolve(
        sessionID: sessionID,
        availableSessionIDs: Set(sessions.map(\.sessionId)),
        catalogIsReady: sessionCatalogIsReadyForNavigation
      ) {
      case .available:
        presentTerminalCreation(sessionID: sessionID)
      case .waitingForCatalog:
        return
      case .unavailable:
        history.finishDashboardAgentsRestoreRequest(request.requestID)
        pendingNavigationRefreshRequestIDValue = nil
        pendingDecisionNavigationReadinessValue = nil
        store.presentFailureFeedback("The requested session is unavailable")
        return
      }
      history.finishDashboardAgentsRestoreRequest(request.requestID)
      pendingNavigationRefreshRequestIDValue = nil
      pendingDecisionNavigationReadinessValue = nil
      return
    }
    let resolution = store.dashboardDecisionResolution(agents: stateValue.viewState.agents)
    if let selection = DashboardAgentNavigationResolver.selection(
      for: request.target,
      agents: stateValue.viewState.agents,
      decisions: resolution
    ) {
      applyResolvedNavigation(selection, request: request)
      return
    }
    let decisionReadiness = decisionReadinessIfNeeded(for: request)
    if refreshesAutomatically,
      isRouteVisible,
      pendingNavigationRefreshRequestIDValue != request.requestID
    {
      pendingNavigationRefreshRequestIDValue = request.requestID
      requestRefresh(force: true)
      return
    }
    guard stateValue.viewState.hasAttemptedLoad, !stateValue.viewState.isLoading else { return }
    guard
      decisionReadiness?.canReportUnavailable(
        currentRefreshTick: store.supervisorDecisionRefreshTick
      ) ?? true
    else { return }
    history.finishDashboardAgentsRestoreRequest(request.requestID)
    pendingNavigationRefreshRequestIDValue = nil
    pendingDecisionNavigationReadinessValue = nil
    store.presentFailureFeedback("The requested agent or decision is unavailable")
  }

  private func applyResolvedNavigation(
    _ selection: DashboardAgentsSelection,
    request: DashboardAgentsNavigationRestoreRequest
  ) {
    persistedSelectionRawValue = selection.rawValue
    if case .decision(let decisionID) = request.target {
      store.supervisorSelectedDecisionID = decisionID
      store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
    }
    history.finishDashboardAgentsRestoreRequest(request.requestID)
    pendingNavigationRefreshRequestIDValue = nil
    pendingDecisionNavigationReadinessValue = nil
  }

  private func decisionReadinessIfNeeded(
    for request: DashboardAgentsNavigationRestoreRequest
  ) -> DashboardDecisionNavigationReadiness? {
    guard case .decision(let decisionID) = request.target else {
      pendingDecisionNavigationReadinessValue = nil
      return nil
    }
    if store.supervisorOpenDecisions.contains(where: { $0.id == decisionID }) {
      pendingDecisionNavigationReadinessValue = nil
      return nil
    }
    let requiresRefresh =
      store.supervisorDecisionRefreshTick == 0
      || store.acpPermissionDecisionPayload(for: decisionID) != nil
    guard requiresRefresh else {
      pendingDecisionNavigationReadinessValue = nil
      return nil
    }
    if let current = pendingDecisionNavigationReadinessValue,
      current.requestID == request.requestID
    {
      return current
    }
    let readiness = DashboardDecisionNavigationReadiness(
      requestID: request.requestID,
      initialRefreshTick: store.supervisorDecisionRefreshTick
    )
    pendingDecisionNavigationReadinessValue = readiness
    return readiness
  }
}

struct DashboardDecisionNavigationReadiness: Equatable {
  let requestID: Int
  let initialRefreshTick: Int

  func canReportUnavailable(currentRefreshTick: Int) -> Bool {
    currentRefreshTick != initialRefreshTick
  }
}

enum DashboardTerminalCreationNavigationResolution: Equatable {
  case available
  case waitingForCatalog
  case unavailable

  static func resolve(
    sessionID: String,
    availableSessionIDs: Set<String>,
    catalogIsReady: Bool
  ) -> Self {
    if availableSessionIDs.contains(sessionID) { return .available }
    return catalogIsReady ? .unavailable : .waitingForCatalog
  }
}
