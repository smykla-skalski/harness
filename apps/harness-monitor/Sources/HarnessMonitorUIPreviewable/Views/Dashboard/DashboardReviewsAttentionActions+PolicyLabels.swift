import HarnessMonitorKit
import SwiftUI

func dashboardReviewsPolicyStepLabel(
  _ step: ReviewsPolicyPreviewStep,
  mergeMethod: TaskBoardGitHubMergeMethod
) -> String {
  switch step.stepType {
  case .action:
    return dashboardReviewsPolicyActionLabel(
      step.actionKey,
      mergeMethod: mergeMethod
    )
  case .wait:
    if let waitingLabel = dashboardReviewsPolicyWaitLabel(step.waitingOn) {
      return "Wait for \(waitingLabel)"
    }
    return "Wait for the configured policy condition"
  case .unknown(let rawValue):
    if let actionKey = step.actionKey, !actionKey.isEmpty {
      return dashboardReviewsPolicyActionLabel(
        actionKey,
        mergeMethod: mergeMethod
      )
    }
    return rawValue.replacingOccurrences(of: "_", with: " ")
  }
}

func dashboardReviewsPolicyWaitLabel(_ wait: ReviewsPolicyWait?) -> String? {
  guard let wait else { return nil }
  if let eventKey = wait.eventKey?.trimmingCharacters(in: .whitespacesAndNewlines),
    !eventKey.isEmpty
  {
    return dashboardReviewsPolicyEventLabel(eventKey)
  }
  if let durationSeconds = wait.durationSeconds, durationSeconds > 0 {
    return dashboardReviewsPolicyDurationLabel(durationSeconds)
  }
  return nil
}

func dashboardReviewsPolicyActionLabel(
  _ actionKey: String?,
  mergeMethod: TaskBoardGitHubMergeMethod
) -> String {
  guard let actionKey, !actionKey.isEmpty else {
    return "Run the configured policy action"
  }
  switch actionKey {
  case "reviews.approve":
    return "Approve the pull request"
  case "reviews.merge":
    return "Merge the pull request using \(mergeMethod.title)"
  default:
    return
      actionKey
      .replacingOccurrences(of: ".", with: " ")
      .replacingOccurrences(of: "_", with: " ")
  }
}

func dashboardReviewsPolicyEventLabel(_ eventKey: String) -> String {
  switch eventKey {
  case "reviews.checks_passed":
    "required checks to pass"
  default:
    eventKey.replacingOccurrences(of: "_", with: " ")
  }
}

func dashboardReviewsPolicyDurationLabel(_ durationSeconds: Int) -> String {
  if durationSeconds % 3600 == 0 {
    let hours = durationSeconds / 3600
    return hours == 1 ? "1 hour" : "\(hours) hours"
  }
  if durationSeconds % 60 == 0 {
    let minutes = durationSeconds / 60
    return minutes == 1 ? "1 minute" : "\(minutes) minutes"
  }
  return durationSeconds == 1 ? "1 second" : "\(durationSeconds) seconds"
}

func dashboardReviewsNumberedLines(_ lines: [String]) -> String {
  lines.enumerated()
    .map { index, line in "\(index + 1). \(line)" }
    .joined(separator: "\n")
}
