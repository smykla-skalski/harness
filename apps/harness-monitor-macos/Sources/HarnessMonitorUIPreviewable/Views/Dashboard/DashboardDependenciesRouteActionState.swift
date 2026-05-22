import HarnessMonitorKit

struct DashboardDependenciesRouteActionState {
  var capabilities = DependencyUpdatesCapabilitiesResponse.fallback
  var recentActions: [String: DashboardDependencyActivityEntry] = [:]
  var pendingConfirmation: DashboardDependencyActionConfirmation?
}
