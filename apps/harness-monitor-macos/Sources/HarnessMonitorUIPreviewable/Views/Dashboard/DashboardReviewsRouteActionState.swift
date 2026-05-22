import HarnessMonitorKit

struct DashboardReviewsRouteActionState {
  var capabilities = ReviewsCapabilitiesResponse.fallback
  var recentActions: [String: DashboardReviewActivityEntry] = [:]
  var pendingConfirmation: DashboardReviewActionConfirmation?
}
