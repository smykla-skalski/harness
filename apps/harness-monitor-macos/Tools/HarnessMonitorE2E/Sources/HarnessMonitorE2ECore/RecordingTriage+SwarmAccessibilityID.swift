extension RecordingTriage {
  /// Mirror of the canonical UI accessibility identifiers emitted by
  /// `HarnessMonitorAccessibility` (see
  /// `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibility+Review.swift`
  /// and `HarnessMonitorAccessibility+Slug.swift`). The HarnessMonitorE2E
  /// SwiftPM package cannot import the Tuist-managed Previewable framework,
  /// so the slug rule and identifier shape are duplicated here. Tests pin
  /// both sides to fixture identifiers copied verbatim from real
  /// `ui-snapshots` captures so future drift trips a red test instead of
  /// silently emitting `not-found` rows on every recording.
  public enum SwarmAccessibilityID {
    public static func slug(_ value: String) -> String {
      var result = value.lowercased()
      result = result.replacingOccurrences(of: " ", with: "-")
      result = result.replacingOccurrences(of: "_", with: "-")
      result = result.replacingOccurrences(of: ":", with: "-")
      result = result.replacingOccurrences(of: "/", with: "-")
      result = result.replacingOccurrences(of: ".", with: "")
      return result
    }

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

    public static func partialAgreementChip(_ pointID: String) -> String {
      "partialAgreementChip.point.\(slug(pointID))"
    }

    public static func roundCounter(_ taskID: String) -> String {
      "harness.inspector.task.round-counter.\(slug(taskID))"
    }

    public static func arbitrationBanner(_ taskID: String) -> String {
      "harness.banner.arbitration.\(slug(taskID))"
    }
  }
}
