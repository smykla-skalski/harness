import HarnessMonitorIntents
import HarnessMonitorKit
import SwiftUI

struct DashboardReviewsActionFeedback: Equatable, Sendable {
  let severity: ActionFeedback.Severity
  let message: String
}

struct DashboardReviewsAutoPolicyOutcome: Equatable, Sendable {
  let item: ReviewItem
  let preview: ReviewsPolicyPreviewResponse?
  let run: ReviewsPolicyRunResponse?
  let status: ReviewsPolicyStatusResponse?
  let skippedReason: String?
  let errorMessage: String?

  var resolvedStatus: ReviewsPolicyStatusResponse? {
    dashboardReviewsResolvedPolicyStatus(status, fallbackRun: run)
  }

  var resolvedRun: ReviewsPolicyRunResponse? {
    if let activeRun = resolvedStatus?.activeRun {
      return activeRun
    }
    if let run,
      let matchingRun = resolvedStatus?.recentRuns.first(where: { $0.runID == run.runID })
    {
      return matchingRun
    }
    return dashboardReviewsLatestPolicyRun(resolvedStatus) ?? run
  }

  var finalStatus: ReviewsPolicyRunStatus? {
    resolvedRun?.status
  }

  func activityEntry(title: String) -> DashboardReviewActivityEntry {
    DashboardReviewActivityEntry(
      title: title,
      summary: dashboardReviewsAutoPolicyActivitySummary(self),
      outcome: dashboardReviewsAutoPolicyActivityOutcome(self),
      messages: dashboardReviewsAutoPolicyActivityMessages(self)
    )
  }
}

func dashboardReviewsAutoPolicyFeedback(
  items: [ReviewItem],
  outcomes: [DashboardReviewsAutoPolicyOutcome]
) -> DashboardReviewsActionFeedback {
  guard items.count > 1 else {
    guard let outcome = outcomes.first else {
      return DashboardReviewsActionFeedback(
        severity: .failure,
        message: "Auto policy failed to start."
      )
    }
    return dashboardSingleReviewAutoPolicyFeedback(outcome)
  }

  // Only `.completed` counts as a success. `.waiting`/`.running`/`.pending`
  // are still in flight. Everything else - `.failed`, `.cancelled`,
  // `.unknown(_)`, an error, or a run that never started - is surfaced as
  // needs-attention so the aggregate never renders an all-green success while
  // any run is unfinished.
  let counts = DashboardReviewsAutoPolicyAggregateCounts(outcomes: outcomes)
  let severity = dashboardReviewsAutoPolicyAggregateSeverity(
    counts,
    outcomeCount: outcomes.count
  )

  var message = "Auto policy summary: \(counts.partsDescription)."
  if let detail = outcomes.lazy.compactMap(dashboardReviewsAutoPolicyDetailMessage(_:)).first,
    severity != .success
  {
    message += " \(detail)"
  }
  return DashboardReviewsActionFeedback(severity: severity, message: message)
}

private struct DashboardReviewsAutoPolicyAggregateCounts {
  let completed: Int
  let waiting: Int
  let running: Int
  let skipped: Int
  let cancelled: Int
  let failed: Int

  init(outcomes: [DashboardReviewsAutoPolicyOutcome]) {
    completed = outcomes.count { $0.policyAggregationClass == .completed }
    waiting = outcomes.count { $0.policyAggregationClass == .waiting }
    running = outcomes.count { $0.policyAggregationClass == .running }
    skipped = outcomes.count { $0.policyAggregationClass == .skipped }
    cancelled = outcomes.count { $0.policyAggregationClass == .cancelled }
    failed = outcomes.count { $0.policyAggregationClass == .failed }
  }

  var partsDescription: String {
    var parts: [String] = []
    appendPart(&parts, completed, "completed")
    appendPart(&parts, waiting, "waiting")
    appendPart(&parts, running, "running")
    appendPart(&parts, skipped, "skipped")
    appendPart(&parts, cancelled, "cancelled")
    appendPart(&parts, failed, "failed")
    if parts.isEmpty {
      parts.append("no pull requests started")
    }
    return parts.joined(separator: ", ")
  }

  private func appendPart(_ parts: inout [String], _ count: Int, _ label: String) {
    guard count > 0 else { return }
    parts.append("\(count) \(label)")
  }
}

private func dashboardReviewsAutoPolicyAggregateSeverity(
  _ counts: DashboardReviewsAutoPolicyAggregateCounts,
  outcomeCount: Int
) -> ActionFeedback.Severity {
  if counts.failed > 0 || counts.cancelled > 0 {
    return .failure
  }
  if counts.completed == outcomeCount {
    return .success
  }
  return .warning
}

func dashboardReviewsActionFeedback(
  title _: String,
  items: [ReviewItem],
  response: ReviewsActionResponse
) -> DashboardReviewsActionFeedback {
  if items.count == 1,
    let item = items.first,
    response.results.contains(where: dashboardReviewsIsAutoAction(result:))
  {
    return dashboardSingleReviewAutoActionFeedback(item: item, response: response)
  }
  return dashboardGenericReviewActionFeedback(response: response)
}

private func dashboardSingleReviewAutoActionFeedback(
  item: ReviewItem,
  response: ReviewsActionResponse
) -> DashboardReviewsActionFeedback {
  let pullRequestLabel = "\(item.repository)#\(item.number)"
  let approvalApplied = response.results.contains {
    $0.action == .autoApprove && $0.outcome == .applied
  }
  let mergeApplied = response.results.contains {
    $0.action == .autoMerge && $0.outcome == .applied
  }
  let approvalFailure = response.results.first {
    $0.action == .autoApprove && $0.outcome == .failed
  }
  let mergeFailure = response.results.first {
    $0.action == .autoMerge && $0.outcome == .failed
  }

  if let mergeFailure {
    let failureMessage = dashboardReviewsFailureMessage(
      mergeFailure.message,
      fallback: "GitHub rejected the merge"
    )
    if approvalApplied {
      return DashboardReviewsActionFeedback(
        severity: .failure,
        message: "Approved \(pullRequestLabel), but merge failed: \(failureMessage)"
      )
    }
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "Merge failed for \(pullRequestLabel): \(failureMessage)"
    )
  }

  if let approvalFailure {
    let failureMessage = dashboardReviewsFailureMessage(
      approvalFailure.message,
      fallback: "GitHub rejected the approval"
    )
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "Approval failed for \(pullRequestLabel): \(failureMessage)"
    )
  }

  if approvalApplied && mergeApplied {
    return DashboardReviewsActionFeedback(
      severity: .success,
      message: "Approved and merged \(pullRequestLabel)"
    )
  }
  if mergeApplied {
    return DashboardReviewsActionFeedback(
      severity: .success,
      message: "Merged \(pullRequestLabel)"
    )
  }
  if approvalApplied {
    let message =
      item.reviewStatus == .reviewRequired
      ? "Approved \(pullRequestLabel). GitHub still requires review before merge."
      : "Approved \(pullRequestLabel)"
    return DashboardReviewsActionFeedback(
      severity: .success,
      message: message
    )
  }
  return dashboardGenericReviewActionFeedback(response: response)
}

private func dashboardGenericReviewActionFeedback(
  response: ReviewsActionResponse
) -> DashboardReviewsActionFeedback {
  let failedMessages = response.results
    .filter { $0.outcome == .failed }
    .compactMap(\.message)
    .map(\.harnessMonitorTrimmedTrailingPeriod)
  if let firstFailure = failedMessages.first {
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "\(response.summary.harnessMonitorTrimmedTrailingPeriod). \(firstFailure)"
    )
  }
  if response.results.contains(where: { $0.outcome == .failed }) {
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: response.summary
    )
  }
  return DashboardReviewsActionFeedback(
    severity: .success,
    message: response.summary
  )
}

func dashboardReviewsFailureMessage(
  _ message: String?,
  fallback: String
) -> String {
  guard let message, !message.isEmpty else {
    return fallback
  }
  return message.harnessMonitorTrimmedTrailingPeriod
}

private func dashboardReviewsIsAutoAction(result: ReviewActionResult) -> Bool {
  result.action == .autoApprove || result.action == .autoMerge
}
