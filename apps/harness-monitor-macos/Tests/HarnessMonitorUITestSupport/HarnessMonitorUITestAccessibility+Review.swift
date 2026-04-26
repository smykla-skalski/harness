extension HarnessMonitorUITestAccessibility {
  static let metricAwaitingReviewAgent = "harness.metrics.awaiting-review-agent"
  static let metricAwaitingReviewTask = "harness.metrics.awaiting-review-task"
  static let metricInReviewTask = "harness.metrics.in-review-task"
  static let metricArbitrationTask = "harness.metrics.arbitration-task"

  static let workerRefusalToast = "harness.toast.worker-refusal"
  static let signalCollisionToast = "harness.toast.signal-collision"
  static let observeScanButton = "observeScanButton"
  static let observeDoctorButton = "observeDoctorButton"

  static func awaitingReviewBadge(_ taskID: String) -> String {
    "harness.review.task.awaiting.\(slug(taskID))"
  }

  static func reviewerClaimBadge(_ taskID: String, runtime: String) -> String {
    "harness.review.task.reviewer-claim.\(slug(taskID)).\(slug(runtime))"
  }

  static func reviewerQuorumIndicator(_ taskID: String) -> String {
    "harness.review.task.reviewer-quorum.\(slug(taskID))"
  }

  static func reviewPointChip(_ pointID: String) -> String {
    "harness.review.task.review-point.\(slug(pointID))"
  }

  static func partialAgreementChip(_ pointID: String) -> String {
    "partialAgreementChip.point.\(slug(pointID))"
  }

  static func roundCounter(_ taskID: String) -> String {
    "harness.review.task.round-counter.\(slug(taskID))"
  }

  static func improverTaskCard(_ taskID: String) -> String {
    "harness.review.task.improver.\(slug(taskID))"
  }

  static func arbitrationBanner(_ taskID: String) -> String {
    "harness.banner.arbitration.\(slug(taskID))"
  }

  static func heuristicIssueCard(_ code: String) -> String {
    "heuristicIssueCard.\(code)"
  }

  static func autoSpawnedBadge(_ agentID: String) -> String {
    "harness.sidebar.agent.\(slug(agentID)).auto-spawned"
  }
}
