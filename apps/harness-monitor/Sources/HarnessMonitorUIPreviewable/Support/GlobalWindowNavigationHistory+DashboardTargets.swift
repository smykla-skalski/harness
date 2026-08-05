import HarnessMonitorKit

extension GlobalWindowNavigationHistory {
  func requestDashboardSelection(_ selection: DashboardWindowSelection) {
    restoreRequestSequence += 1
    recordDashboardJump(selection)
    prepareDashboardRestore(selection)
    navigator?(.dashboard(selection: selection))
  }

  func prepareDashboardRestore(_ selection: DashboardWindowSelection) {
    dashboardSelection = selection
    pendingSessionRestoreRequest = nil
    pendingDashboardRestoreRequest = DashboardWindowNavigationRestoreRequest(
      requestID: restoreRequestSequence,
      selection: selection
    )
    pendingDashboardAgentsRestoreRequest =
      switch selection {
      case .agents(let target): .init(requestID: restoreRequestSequence, target: target)
      default: nil
      }
    pendingDashboardTaskBoardRestoreRequest =
      switch selection {
      case .taskBoard(let target): .init(requestID: restoreRequestSequence, target: target)
      default: nil
      }
    pendingDashboardAuditRestoreRequest = dashboardAuditRestoreRequest(for: selection)
    pendingDashboardReviewsRestoreRequest =
      switch selection {
      case .reviews(let reviewsSelection):
        .init(requestID: restoreRequestSequence, selection: reviewsSelection)
      default: nil
      }
  }

  private func dashboardAuditRestoreRequest(
    for selection: DashboardWindowSelection
  ) -> DashboardAuditNavigationRestoreRequest? {
    switch selection {
    case .audit(let target):
      .init(requestID: restoreRequestSequence, target: target)
    case .route(.audit):
      .init(requestID: restoreRequestSequence, target: nil)
    default:
      nil
    }
  }

  func dashboardSelection(
    for selection: SessionSelection,
    sessionID: String
  ) -> DashboardWindowSelection {
    switch selection {
    case .agent(_, let agentID):
      .agents(.sessionAgent(sessionID: sessionID, agentID: agentID))
    case .codexRun(_, let runID):
      .agents(.managedAgent(sessionID: sessionID, runtimeKind: .codex, managedAgentID: runID))
    case .openRouterRun:
      .agents(.session(sessionID: sessionID))
    case .decision(_, let decisionID):
      .agents(.decision(decisionID: decisionID))
    case .task(_, let taskID):
      .taskBoard(.sessionTask(sessionID: sessionID, taskID: taskID))
    case .create(let draft):
      createSelection(kind: draft.kind)
    case .route(let route):
      routeSelection(route, sessionID: sessionID)
    }
  }

  private func createSelection(kind: SessionCreateKind) -> DashboardWindowSelection {
    if kind == .task {
      return .route(.taskBoard)
    }
    return .route(.agents)
  }

  private func routeSelection(
    _ route: SessionWindowRoute,
    sessionID: String
  ) -> DashboardWindowSelection {
    switch route {
    case .tasks:
      .route(.taskBoard)
    case .timeline:
      .route(.audit)
    case .policyCanvas:
      .route(.policyCanvas)
    case .overview, .agents, .decisions:
      .agents(.session(sessionID: sessionID))
    }
  }
}
