extension HarnessMonitorAccessibility {
  public static func awaitingReviewBadge(_ taskID: String) -> String {
    "harness.inspector.task.awaiting-review-badge.\(slug(taskID))"
  }

  public static func reviewerClaimBadge(_ taskID: String, runtime: String) -> String {
    "harness.inspector.task.reviewer-claim-badge.\(slug(taskID)).\(slug(runtime))"
  }

  public static func reviewerQuorumIndicator(_ taskID: String) -> String {
    "harness.inspector.task.reviewer-quorum.\(slug(taskID))"
  }

  public static func reviewPointChip(_ pointID: String) -> String {
    "harness.inspector.task.review-point.\(slug(pointID))"
  }

  public static func roundCounter(_ taskID: String) -> String {
    "harness.inspector.task.round-counter.\(slug(taskID))"
  }

  public static func improverTaskCard(_ taskID: String) -> String {
    "harness.inspector.task.improver-card.\(slug(taskID))"
  }
}
