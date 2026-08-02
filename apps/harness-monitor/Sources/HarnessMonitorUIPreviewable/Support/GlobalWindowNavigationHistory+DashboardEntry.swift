func shouldUpgradeDashboardHistoryEntry(
  _ currentEntry: GlobalWindowNavigationEntry?,
  _ selection: DashboardWindowSelection,
  _ hasPendingRestore: Bool
) -> Bool {
  guard !hasPendingRestore, let currentEntry else { return false }
  switch currentEntry {
  case .dashboard(selection: .route(.reviews)):
    return selection.route == .reviews
  case .dashboard(selection: .route(.agents)):
    return selection.route == .agents
  default:
    return false
  }
}

func shouldReplaceInitialDashboardHistoryEntry(
  _ currentEntry: GlobalWindowNavigationEntry?,
  _ selection: DashboardWindowSelection,
  _ backStackIsEmpty: Bool,
  _ forwardStackIsEmpty: Bool
) -> Bool {
  guard backStackIsEmpty && forwardStackIsEmpty else { return false }
  return currentEntry
    == .dashboard(
      selection: .route(DashboardRouteRestorationDefaults.defaultRoute)
    )
    && selection != .route(DashboardRouteRestorationDefaults.defaultRoute)
}
