import HarnessMonitorKit

struct DashboardReviewsRouteActionState {
  var capabilities = ReviewsCapabilitiesResponse.fallback
  var recentActions: [String: DashboardReviewActivityEntry] = [:]
  var pendingConfirmation: DashboardReviewActionConfirmation?
  var pastedTextReviewSheet: DashboardReviewsPastedTextReviewSheetState?
  var handledScreenshotPasteboardRequestID = 0
  var policyPreviewByPullRequestID: [String: ReviewsPolicyPreviewResponse] = [:]
  var policyStatusByPullRequestID: [String: ReviewsPolicyStatusResponse] = [:]
}
