import Foundation
import HarnessMonitorCore

extension CommandFormModel {
  /// Builds the command draft for the current fields. A selected review or task
  /// produces that entity's draft (with its own confirmation text); otherwise a
  /// manual-target draft is built using the view-supplied `confirmationText`.
  public func makeDraft(confirmationText: String) -> MobileCommandDraft {
    if let reviewDraft = selectedReviewDraft {
      return reviewDraft
    }
    if let taskDraft = selectedTaskDraft {
      return taskDraft
    }
    let target = MobileCommandTarget(
      stationID: effectiveStationID,
      sessionID: sessionID.trimmedCommandValue,
      agentID: agentID.trimmedCommandValue,
      reviewID: reviewID.trimmedCommandValue,
      taskID: taskID.trimmedCommandValue,
      targetRevision: store.snapshot.revision
    )
    return MobileCommandDraft(
      kind: kind,
      confirmationText: confirmationText,
      auditReason: auditReason.trimmedCommandValue,
      target: target,
      payload: payload,
      expiresAfter: profile.commandExpiry
    )
  }

  public var selectedReview: MobileReviewSummary? {
    store.snapshot.reviews.first { $0.id == reviewID && $0.stationID == effectiveStationID }
  }

  public var selectedTask: MobileTaskBoardSummary? {
    store.snapshot.taskBoardItems.first { $0.id == taskID && $0.stationID == effectiveStationID }
  }

  var selectedReviewDraft: MobileCommandDraft? {
    guard let review = selectedReview else {
      return nil
    }
    switch kind {
    case .pullRequestApprove, .pullRequestLabel, .pullRequestRerunChecks, .pullRequestMerge:
      return review.commandDraft(
        kind: kind,
        targetRevision: store.snapshot.revision,
        label: label,
        mergeMethod: mergeMethod,
        auditReason: auditReason.trimmedCommandValue,
        expiresAfter: profile.commandExpiry
      )
    default:
      return nil
    }
  }

  var selectedTaskDraft: MobileCommandDraft? {
    guard let task = selectedTask else {
      return nil
    }
    switch kind {
    case .taskBoardDispatch:
      var draft = task.commandDraft(
        kind: .taskBoardDispatch,
        targetRevision: store.snapshot.revision,
        status: taskStatus,
        expiresAfter: profile.commandExpiry
      )
      if profile.includesDryRun {
        draft.payload["dryRun"] = dryRun ? "true" : "false"
      }
      return draft
    case .taskBoardPlanApproval:
      return task.commandDraft(
        kind: .taskBoardPlanApproval,
        targetRevision: store.snapshot.revision,
        expiresAfter: profile.commandExpiry
      )
    default:
      return nil
    }
  }

  var payload: [String: String] {
    var payload: [String: String] = [:]
    switch kind {
    case .acpPermissionDecision:
      payload["batchID"] = batchID
      payload["decision"] = acpDecision
    case .taskBoardDispatch:
      payload["status"] = taskStatus
      if profile.includesDryRun {
        payload["dryRun"] = dryRun ? "true" : "false"
      }
    case .taskBoardPlanApproval, .agentStop, .pullRequestApprove, .pullRequestRerunChecks:
      break
    case .agentStart:
      payload["agent"] = agent
      payload["role"] = role
      payload["prompt"] = resolvedPrompt
    case .agentPrompt:
      payload["prompt"] = resolvedPrompt
    case .pullRequestLabel:
      payload["label"] = label
      addManualReviewPayload(to: &payload)
    case .pullRequestMerge:
      payload["method"] = mergeMethod
      addManualReviewPayload(to: &payload)
    case .refresh:
      payload["scope"] = refreshScope
      if refreshScope == "reviews" {
        addManualReviewPayload(to: &payload)
      }
    }
    if kind == .pullRequestApprove || kind == .pullRequestRerunChecks {
      addManualReviewPayload(to: &payload)
    }
    return payload
  }

  func addManualReviewPayload(to payload: inout [String: String]) {
    if let repository = repository.trimmedCommandValue {
      payload["repository"] = repository
    }
    if let reviewNumber = reviewNumber.trimmedCommandValue {
      payload["number"] = reviewNumber
    }
  }
}
