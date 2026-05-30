import HarnessMonitorIntents
import HarnessMonitorKit
import SwiftUI

func dashboardReviewAutoPolicyOutcome(
  item: ReviewItem,
  mergeMethod: TaskBoardGitHubMergeMethod,
  client: any HarnessMonitorClientProtocol
) async -> DashboardReviewsAutoPolicyOutcome {
  let preview: ReviewsPolicyPreviewResponse
  do {
    preview = try await DashboardReviewsTimeoutRacer.race(
      timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
    ) {
      try await client.previewReviewsPolicy(
        ReviewsPolicyPreviewRequest(
          target: item.target,
          method: mergeMethod
        )
      )
    }
  } catch {
    return DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: nil,
      run: nil,
      status: nil,
      skippedReason: nil,
      errorMessage: error.localizedDescription
    )
  }

  guard preview.eligible, !preview.steps.isEmpty else {
    return DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: preview,
      run: nil,
      status: nil,
      skippedReason: preview.reason ?? "No policy actions are currently applicable.",
      errorMessage: nil
    )
  }

  let run: ReviewsPolicyRunResponse
  do {
    run = try await DashboardReviewsTimeoutRacer.race(
      timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
    ) {
      try await client.startReviewsPolicyRun(
        ReviewsPolicyRunStartRequest(
          target: item.target,
          method: mergeMethod,
          trigger: .manual
        )
      )
    }
  } catch {
    return DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: preview,
      run: nil,
      status: nil,
      skippedReason: nil,
      errorMessage: error.localizedDescription
    )
  }

  do {
    let status = try await DashboardReviewsTimeoutRacer.race(
      timeoutSeconds: DashboardReviewsTimeoutRacer.defaultMutationTimeoutSeconds
    ) {
      try await client.reviewsPolicyStatus(
        ReviewsPolicyStatusRequest(
          subject: run.subject,
          workflowID: run.workflowID
        )
      )
    }
    return DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: preview,
      run: run,
      status: status,
      skippedReason: nil,
      errorMessage: nil
    )
  } catch {
    HarnessMonitorLogger.api.warning(
      """
      Reviews policy status refresh failed for \(item.repository)#\(item.number): \
      \(String(reflecting: error), privacy: .public)
      """
    )
    return DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: preview,
      run: run,
      status: nil,
      skippedReason: nil,
      errorMessage: nil
    )
  }
}

func dashboardReviewsResolvedPolicyStatus(
  _ status: ReviewsPolicyStatusResponse?,
  fallbackRun: ReviewsPolicyRunResponse?
) -> ReviewsPolicyStatusResponse? {
  if let status,
    status.activeRun != nil || !status.recentRuns.isEmpty
  {
    return status
  }
  guard let fallbackRun else { return status }
  return ReviewsPolicyStatusResponse(
    activeRun: fallbackRun.status.isActive ? fallbackRun : nil,
    recentRuns: [fallbackRun]
  )
}

func dashboardSingleReviewAutoPolicyFeedback(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> DashboardReviewsActionFeedback {
  let pullRequestLabel = "\(outcome.item.repository)#\(outcome.item.number)"
  if let errorMessage = outcome.errorMessage {
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "Auto policy failed for \(pullRequestLabel): "
        + dashboardReviewsFailureMessage(errorMessage, fallback: "Unknown error")
    )
  }
  if let skippedReason = outcome.skippedReason {
    return DashboardReviewsActionFeedback(
      severity: .warning,
      message: "Auto policy did not start for \(pullRequestLabel): "
        + dashboardReviewsFailureMessage(skippedReason, fallback: "Not eligible")
    )
  }

  switch outcome.finalStatus {
  case .completed:
    return dashboardSingleReviewAutoPolicyCompletedFeedback(
      outcome,
      pullRequestLabel: pullRequestLabel
    )
  case .waiting:
    return dashboardSingleReviewAutoPolicyWaitingFeedback(
      outcome,
      pullRequestLabel: pullRequestLabel
    )
  case .pending, .running:
    return DashboardReviewsActionFeedback(
      severity: .warning,
      message: "Auto policy started for \(pullRequestLabel)."
    )
  case .cancelled:
    return DashboardReviewsActionFeedback(
      severity: .warning,
      message: "Auto policy was cancelled for \(pullRequestLabel)."
    )
  case .failed:
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "Auto policy failed for \(pullRequestLabel): "
        + dashboardReviewsFailureMessage(
          outcome.resolvedRun?.errorMessage,
          fallback: "Unknown error"
        )
    )
  case .unknown(let rawValue):
    return DashboardReviewsActionFeedback(
      severity: .warning,
      message: "Auto policy entered \(rawValue) for \(pullRequestLabel)."
    )
  case nil:
    return DashboardReviewsActionFeedback(
      severity: .failure,
      message: "Auto policy failed to start for \(pullRequestLabel)."
    )
  }
}

private func dashboardSingleReviewAutoPolicyCompletedFeedback(
  _ outcome: DashboardReviewsAutoPolicyOutcome,
  pullRequestLabel: String
) -> DashboardReviewsActionFeedback {
  if let effects = dashboardReviewsJoinedPolicyEffects(
    dashboardReviewsAutoPolicyEffects(outcome.resolvedRun?.steps ?? [])
  ) {
    return DashboardReviewsActionFeedback(
      severity: .success,
      message: "Auto policy completed for \(pullRequestLabel): \(effects)."
    )
  }
  return DashboardReviewsActionFeedback(
    severity: .success,
    message: "Auto policy completed for \(pullRequestLabel)."
  )
}

private func dashboardSingleReviewAutoPolicyWaitingFeedback(
  _ outcome: DashboardReviewsAutoPolicyOutcome,
  pullRequestLabel: String
) -> DashboardReviewsActionFeedback {
  let waitingLabel =
    dashboardReviewsPolicyWaitLabel(outcome.resolvedRun?.waitingOn)
    ?? "the configured policy condition"
  if let effects = dashboardReviewsJoinedPolicyEffects(
    dashboardReviewsAutoPolicyEffects(outcome.resolvedRun?.steps ?? [])
  ) {
    return DashboardReviewsActionFeedback(
      severity: .warning,
      message:
        "Auto policy started for \(pullRequestLabel): \(effects); waiting for \(waitingLabel)."
    )
  }
  return DashboardReviewsActionFeedback(
    severity: .warning,
    message: "Auto policy started for \(pullRequestLabel) and is waiting for \(waitingLabel)."
  )
}

func dashboardReviewsAutoPolicyDetailMessage(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> String? {
  let pullRequestLabel = "\(outcome.item.repository)#\(outcome.item.number)"
  if let errorMessage = outcome.errorMessage {
    return "\(pullRequestLabel): "
      + dashboardReviewsFailureMessage(errorMessage, fallback: "Unknown error")
  }
  if let skippedReason = outcome.skippedReason {
    return "\(pullRequestLabel): "
      + dashboardReviewsFailureMessage(skippedReason, fallback: "Not eligible")
  }
  switch outcome.finalStatus {
  case .failed:
    return "\(pullRequestLabel): "
      + dashboardReviewsFailureMessage(
        outcome.resolvedRun?.errorMessage,
        fallback: "Unknown error"
      )
  case .cancelled:
    return "\(pullRequestLabel) was cancelled."
  case .unknown(let rawValue):
    return "\(pullRequestLabel) entered \(rawValue)."
  case nil:
    return "\(pullRequestLabel) failed to start."
  default:
    return nil
  }
}

func dashboardReviewsAutoPolicyActivityOutcome(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> DashboardReviewActivityEntry.Outcome {
  if outcome.errorMessage != nil || outcome.finalStatus == .failed || outcome.finalStatus == nil {
    return .failure
  }
  if outcome.finalStatus == .completed {
    return .success
  }
  return .warning
}

func dashboardReviewsAutoPolicyActivitySummary(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> String {
  if let errorMessage = outcome.errorMessage {
    return "Auto policy failed: "
      + dashboardReviewsFailureMessage(errorMessage, fallback: "Unknown error")
  }
  if let skippedReason = outcome.skippedReason {
    return "Auto policy did not start: "
      + dashboardReviewsFailureMessage(skippedReason, fallback: "Not eligible")
  }
  switch outcome.finalStatus {
  case .completed:
    return dashboardReviewsAutoPolicyCompletedSummary(outcome)
  case .waiting:
    if let waitingLabel = dashboardReviewsPolicyWaitLabel(outcome.resolvedRun?.waitingOn) {
      return "Auto policy is waiting for \(waitingLabel)."
    }
    return "Auto policy is waiting."
  case .pending, .running:
    return "Auto policy started."
  case .cancelled:
    return "Auto policy was cancelled."
  case .failed:
    return "Auto policy failed: "
      + dashboardReviewsFailureMessage(
        outcome.resolvedRun?.errorMessage,
        fallback: "Unknown error"
      )
  case .unknown(let rawValue):
    return "Auto policy entered \(rawValue)."
  case nil:
    return "Auto policy failed to start."
  }
}

private func dashboardReviewsAutoPolicyCompletedSummary(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> String {
  if let effects = dashboardReviewsJoinedPolicyEffects(
    dashboardReviewsAutoPolicyEffects(outcome.resolvedRun?.steps ?? [])
  ) {
    return "Auto policy completed: \(effects)."
  }
  return "Auto policy completed."
}

func dashboardReviewsAutoPolicyActivityMessages(
  _ outcome: DashboardReviewsAutoPolicyOutcome
) -> [String] {
  var messages: [String] = []
  if let effects = dashboardReviewsJoinedPolicyEffects(
    dashboardReviewsAutoPolicyEffects(outcome.resolvedRun?.steps ?? [])
  ) {
    messages.append("Completed: \(dashboardReviewsSentenceCase(effects)).")
  }
  if let waitingLabel = dashboardReviewsPolicyWaitLabel(outcome.resolvedRun?.waitingOn) {
    messages.append("Waiting on: \(waitingLabel)")
  }
  if let run = outcome.resolvedRun {
    messages.append("Workflow: \(run.workflowID)")
  }
  return messages
}

private func dashboardReviewsAutoPolicyEffects(
  _ steps: [ReviewsPolicyRunStep]
) -> [String] {
  var effects: [String] = []
  for step in steps where step.stepType == .action {
    switch step.actionKey {
    case "reviews.approve":
      effects.append("approved")
    case "reviews.merge":
      effects.append("merged")
    case let actionKey? where !actionKey.isEmpty:
      effects.append(
        actionKey
          .replacingOccurrences(of: ".", with: " ")
          .replacingOccurrences(of: "_", with: " ")
      )
    default:
      break
    }
  }
  return dashboardReviewsOrderedUniqueEffects(effects)
}

private func dashboardReviewsOrderedUniqueEffects(
  _ effects: [String]
) -> [String] {
  var ordered: [String] = []
  var seen = Set<String>()
  for effect in effects where seen.insert(effect).inserted {
    ordered.append(effect)
  }
  return ordered
}

private func dashboardReviewsJoinedPolicyEffects(
  _ effects: [String]
) -> String? {
  guard let first = effects.first else { return nil }
  guard effects.count > 1 else { return first }
  if effects.count == 2, let last = effects.last {
    return "\(first) and \(last)"
  }
  return effects.dropLast().joined(separator: ", ")
    + ", and "
    + (effects.last ?? "")
}

private func dashboardReviewsSentenceCase(_ value: String) -> String {
  guard let first = value.first else { return value }
  return first.uppercased() + value.dropFirst()
}
