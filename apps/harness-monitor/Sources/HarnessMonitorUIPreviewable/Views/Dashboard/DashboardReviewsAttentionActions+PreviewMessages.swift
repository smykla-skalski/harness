import HarnessMonitorKit
import SwiftUI

func dashboardReviewActionPreviewMessage(
  _ preview: ReviewsActionPreviewResponse
) -> String {
  var lines = [
    "\(preview.actionableCount) of \(preview.totalCount) selected pull requests are eligible."
  ]
  if preview.skippedCount > 0 {
    var skippedReasonCounts: [String: Int] = [:]
    for target in preview.targets where !target.eligible {
      skippedReasonCounts[target.reason ?? "Unavailable", default: 0] += 1
    }
    let skippedReasons =
      skippedReasonCounts
      .map { reason, count in "\(count) \(reason)" }
      .sorted()
      .prefix(3)
      .joined(separator: "\n")
    lines.append("Skipping \(preview.skippedCount):\n\(skippedReasons)")
  }
  lines.append(contentsOf: preview.warnings)
  return lines.joined(separator: "\n")
}

func dashboardReviewAutoPolicyPreviewMessage(
  _ preview: DashboardReviewsAutoPolicyPreview,
  mergeMethod: TaskBoardGitHubMergeMethod
) -> String {
  var lines = [
    "\(preview.actionableCount) of \(preview.totalCount) selected pull requests can start the workflow."
  ]
  if preview.skippedCount > 0 {
    var skippedReasonCounts: [String: Int] = [:]
    for target in preview.targets where !target.eligible {
      skippedReasonCounts[target.reason ?? "Unavailable", default: 0] += 1
    }
    let skippedReasons =
      skippedReasonCounts
      .map { reason, count in "\(count) \(reason)" }
      .sorted()
      .prefix(3)
      .joined(separator: "\n")
    lines.append("Skipping \(preview.skippedCount):\n\(skippedReasons)")
  }
  if let plans = dashboardReviewAutoPolicyPlanMessage(
    preview,
    mergeMethod: mergeMethod
  ) {
    lines.append(plans)
  }
  lines.append(contentsOf: preview.warnings)
  return lines.joined(separator: "\n")
}

func dashboardReviewAutoPolicyPlanMessage(
  _ preview: DashboardReviewsAutoPolicyPreview,
  mergeMethod: TaskBoardGitHubMergeMethod
) -> String? {
  let eligibleTargets = preview.targets.filter(\.eligible)
  guard !eligibleTargets.isEmpty else { return nil }
  let planByLabel = Dictionary(
    grouping: eligibleTargets
  ) { target in
    target.steps
      .map { dashboardReviewsPolicyStepLabel($0, mergeMethod: mergeMethod) }
      .joined(separator: " -> ")
  }
  if eligibleTargets.count == 1,
    let first = eligibleTargets.first
  {
    let steps = first.steps.map { dashboardReviewsPolicyStepLabel($0, mergeMethod: mergeMethod) }
    guard !steps.isEmpty else { return nil }
    return "Planned steps:\n" + dashboardReviewsNumberedLines(steps)
  }
  if planByLabel.count == 1,
    let first = eligibleTargets.first
  {
    let steps = first.steps.map { dashboardReviewsPolicyStepLabel($0, mergeMethod: mergeMethod) }
    guard !steps.isEmpty else { return nil }
    return "Eligible workflow steps:\n" + dashboardReviewsNumberedLines(steps)
  }
  let planLines =
    planByLabel
    .map { plan, targets in
      let countLabel = targets.count == 1 ? "1 PR" : "\(targets.count) PRs"
      return "\(countLabel): \(plan)"
    }
    .sorted()
    .prefix(3)
  guard !planLines.isEmpty else { return nil }
  return "Eligible workflow plans:\n• " + planLines.joined(separator: "\n• ")
}

func dashboardReviewsAutoPolicyWarnings(
  _ targets: [DashboardReviewsAutoPolicyPreviewTarget]
) -> [String] {
  var warningCounts: [String: Int] = [:]
  for target in targets {
    for warning in target.warnings {
      warningCounts[warning, default: 0] += 1
    }
  }
  return
    warningCounts
    .map { warning, count in
      count == 1 ? warning : "\(count) PRs: \(warning)"
    }
    .sorted()
    .prefix(5)
    .map(\.self)
}
