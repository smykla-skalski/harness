extension HarnessMonitorAccessibility {
  public static func awaitingReviewBadge(_ taskID: String) -> String {
    "harness.review.task.awaiting.\(slug(taskID))"
  }

  public static func reviewerClaimBadge(_ taskID: String, runtime: String) -> String {
    "harness.review.task.reviewer-claim.\(slug(taskID)).\(slug(runtime))"
  }

  public static func reviewerQuorumIndicator(_ taskID: String) -> String {
    "harness.review.task.reviewer-quorum.\(slug(taskID))"
  }

  public static func reviewPointChip(_ pointID: String) -> String {
    "harness.review.task.review-point.\(slug(pointID))"
  }

  public static func partialAgreementChip(_ pointID: String) -> String {
    "partialAgreementChip.point.\(slug(pointID))"
  }

  public static func roundCounter(_ taskID: String) -> String {
    "harness.review.task.round-counter.\(slug(taskID))"
  }

  public static func improverTaskCard(_ taskID: String) -> String {
    "harness.review.task.improver.\(slug(taskID))"
  }

  public static func arbitrationBanner(_ taskID: String) -> String {
    "harness.banner.arbitration.\(slug(taskID))"
  }

  public static func heuristicIssueCard(_ code: String) -> String {
    "heuristicIssueCard.\(code)"
  }

  public static let workerRefusalToast = "harness.toast.worker-refusal"
  public static let signalCollisionToast = "harness.toast.signal-collision"
  public static let observeScanButton = "observeScanButton"
  public static let observeDoctorButton = "observeDoctorButton"

  public static let metricAwaitingReviewAgent = "harness.metrics.awaiting-review-agent"
  public static let metricAwaitingReviewTask = "harness.metrics.awaiting-review-task"
  public static let metricInReviewTask = "harness.metrics.in-review-task"
  public static let metricArbitrationTask = "harness.metrics.arbitration-task"
}
