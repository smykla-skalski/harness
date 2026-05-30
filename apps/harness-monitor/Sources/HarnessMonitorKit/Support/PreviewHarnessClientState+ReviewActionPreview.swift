import Foundation

extension PreviewHarnessClientState {
  func previewActionResponse(
    summary: String,
    action: ReviewActionKind,
    _ targets: [ReviewTarget]
  ) -> ReviewsActionResponse {
    ReviewsActionResponse(
      summary: "\(summary): \(targets.count) applied, 0 skipped, 0 failed",
      results: targets.map { target in
        ReviewActionResult(
          repository: target.repository,
          number: target.number,
          action: action,
          outcome: .applied
        )
      }
    )
  }

  func previewReviewActionTarget(
    action: ReviewActionPreviewKind,
    target: ReviewTarget
  ) -> ReviewActionPreviewTarget {
    let reason = previewReviewBlocker(action: action, target: target)
    return ReviewActionPreviewTarget(
      pullRequestID: target.pullRequestID,
      repository: target.repository,
      number: target.number,
      eligible: reason == nil,
      reason: reason,
      warnings: previewReviewTargetWarnings(action: action, target: target)
    )
  }

  func previewReviewBlocker(
    action: ReviewActionPreviewKind,
    target: ReviewTarget
  ) -> String? {
    guard target.viewerCanUpdate else {
      return "Current GitHub token cannot update this pull request"
    }
    guard target.state == .open else {
      return "Pull request is not open"
    }
    switch action {
    case .approve:
      return target.reviewStatus == .reviewRequired || target.reviewStatus == .none
        ? nil
        : "Pull request does not need manual approval"
    case .merge:
      if target.isDraft { return "Draft pull requests cannot be merged" }
      return target.mergeable == .conflicting
        ? "Merge conflicts must be resolved before merging"
        : nil
    case .rerunChecks:
      return target.checkSuiteIDs.isEmpty
        ? "No rerunnable check suites were reported"
        : nil
    case .addLabel:
      return nil
    case .auto:
      return target.isAutoApprovable || target.isAutoMergeable
        ? nil
        : "Pull request is not eligible for auto mode"
    case .unknown:
      return "Unknown review action"
    }
  }

  func previewReviewWarnings(
    action: ReviewActionPreviewKind,
    targets: [ReviewTarget]
  ) -> [String] {
    var warnings: [String] = []
    if action == .approve || action == .merge {
      let failing = targets.count { $0.checkStatus == .failure }
      if failing > 0 {
        warnings.append(
          failing == 1
            ? "1 pull request has failing checks"
            : "\(failing) pull requests have failing checks"
        )
      }
    }
    let policyBlocked = targets.count(where: \.policyBlocked)
    if policyBlocked > 0 {
      warnings.append(
        policyBlocked == 1
          ? "1 pull request is policy-blocked"
          : "\(policyBlocked) pull requests are policy-blocked"
      )
    }
    return warnings
  }

  func previewReviewTargetWarnings(
    action: ReviewActionPreviewKind,
    target: ReviewTarget
  ) -> [String] {
    var warnings: [String] = []
    if (action == .approve || action == .merge) && target.checkStatus == .failure {
      warnings.append("Checks are failing")
    }
    if target.reviewStatus == .changesRequested {
      warnings.append("A reviewer requested changes")
    }
    if target.policyBlocked {
      warnings.append("Review policy is blocking this pull request")
    }
    return warnings
  }
}
