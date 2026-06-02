import Foundation

@MainActor
enum DashboardImagePastePolicyDispatcher {
  enum Result: Equatable {
    case notHandled
    case manualOCRPaste
    case reviewScreenshotPaste
  }

  @discardableResult
  static func requestPasteFromClipboard(
    reviewsRouteActive: Bool,
    policyCenter: AutomationPolicyCenter = .shared
  ) -> Result {
    if reviewsRouteActive,
      reviewScreenshotPolicyCanHandleImagePaste(policyCenter: policyCenter)
    {
      return DashboardReviewsScreenshotPasteboardRequests.requestPasteFromClipboard()
        ? .reviewScreenshotPaste
        : .notHandled
    }
    return DashboardDebuggingOCRPasteboardRequests.requestManualPasteFromClipboard(
      policyCenter: policyCenter
    )
      ? .manualOCRPaste
      : .notHandled
  }

  @discardableResult
  static func requestPaste(
    from transferImages: [DashboardOCRTransferImage],
    reviewsRouteActive: Bool,
    policyCenter: AutomationPolicyCenter = .shared
  ) -> Result {
    if reviewsRouteActive,
      reviewScreenshotPolicyCanHandleImagePaste(policyCenter: policyCenter)
    {
      return DashboardReviewsScreenshotPasteboardRequests.requestPaste(from: transferImages)
        ? .reviewScreenshotPaste
        : .notHandled
    }
    return DashboardDebuggingOCRPasteboardRequests.requestManualPaste(
      from: transferImages,
      policyCenter: policyCenter
    )
      ? .manualOCRPaste
      : .notHandled
  }

  private static func reviewScreenshotPolicyCanHandleImagePaste(
    policyCenter: AutomationPolicyCenter
  ) -> Bool {
    let decision = policyCenter.decision(
      for: .reviewScreenshotPaste,
      contentKinds: [.image],
      allowsPasteboardPrompt: true
    )
    return decision.shouldOCRImages && decision.shouldExtractGitHubPullRequests
  }
}
