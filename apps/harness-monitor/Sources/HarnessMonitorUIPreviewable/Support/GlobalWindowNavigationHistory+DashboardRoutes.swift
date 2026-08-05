extension GlobalWindowNavigationHistory {
  func recordDashboardRoute(_ route: DashboardWindowRoute) {
    guard pendingDashboardRestoreRequest?.route != route else {
      return
    }
    let selection = DashboardWindowSelection.route(route)
    guard dashboardSelection != selection || currentEntry != .dashboard(selection: selection) else {
      return
    }
    userSelectedDashboardRoute(route)
  }

  func userSelectedDashboardRoute(_ route: DashboardWindowRoute) {
    pendingSessionRestoreRequest = nil
    pendingDashboardRestoreRequest = nil
    pendingDashboardAgentsRestoreRequest = nil
    pendingDashboardTaskBoardRestoreRequest = nil
    pendingDashboardAuditRestoreRequest = nil
    pendingDashboardReviewsRestoreRequest = nil
    recordDashboardSelection(.route(route))
    if route == .audit {
      restoreRequestSequence += 1
      pendingDashboardAuditRestoreRequest = DashboardAuditNavigationRestoreRequest(
        requestID: restoreRequestSequence,
        target: nil
      )
    }
  }
}
