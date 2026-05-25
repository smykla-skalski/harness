import HarnessMonitorCore
import SwiftUI

extension MobileCommandComposerView {
  var effectiveStationID: String {
    if !stationID.isEmpty {
      return stationID
    }
    return store.snapshot.stations.first?.id ?? ""
  }

  var sessionsForStation: [MobileSessionSummary] {
    store.snapshot.sessions
      .filter { $0.stationID == effectiveStationID }
      .sorted { $0.lastActivityAt > $1.lastActivityAt }
  }

  var reviewsForStation: [MobileReviewSummary] {
    store.snapshot.reviews
      .filter { $0.stationID == effectiveStationID }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  var taskBoardItemsForStation: [MobileTaskBoardSummary] {
    store.snapshot.taskBoardItems(for: effectiveStationID)
  }

  var validationMessage: String? {
    do {
      try makeDraft().validate()
      if !store.canQueueCommand(stationID: effectiveStationID) {
        return "This station is not paired for live commands."
      }
      return nil
    } catch {
      return String(describing: error)
    }
  }

  var canSubmit: Bool {
    !submitting && validationMessage == nil
  }

  var confirmationText: String {
    let stationName =
      store.snapshot.station(id: effectiveStationID)?.displayName
      ?? "selected station"
    switch kind {
    case .acpPermissionDecision:
      return "\(acpDecisionTitle) ACP permission for \(agentIDOrFallback)."
    case .taskBoardDispatch:
      return "Dispatch task board work on \(stationName)."
    case .taskBoardPlanApproval:
      return "Approve task board plan \(taskIDOrFallback)."
    case .agentStart:
      return "Start \(agent) as \(role) in \(sessionIDOrFallback)."
    case .agentStop:
      return "Stop \(agentIDOrFallback)."
    case .agentPrompt:
      return "Send prompt to \(agentIDOrFallback)."
    case .pullRequestApprove:
      return "Approve \(reviewTitleOrFallback)."
    case .pullRequestLabel:
      return "Apply label \(labelOrFallback) to \(reviewTitleOrFallback)."
    case .pullRequestRerunChecks:
      return "Rerun checks for \(reviewTitleOrFallback)."
    case .pullRequestMerge:
      return "Merge \(reviewTitleOrFallback) with \(mergeMethod)."
    case .refresh:
      return "Refresh \(refreshScopeTitle) on \(stationName)."
    }
  }

  var acpDecisionTitle: String {
    switch acpDecision {
    case "approve_all": "Approve"
    case "deny_all": "Deny"
    case "approve_some": "Partially approve"
    default: acpDecision
    }
  }

  var agentIDOrFallback: String {
    agentID.trimmedForCommandDisplay(ifEmpty: "selected agent")
  }

  var taskIDOrFallback: String {
    taskID.trimmedForCommandDisplay(ifEmpty: "selected task")
  }

  var sessionIDOrFallback: String {
    sessionID.trimmedForCommandDisplay(ifEmpty: "selected session")
  }

  var labelOrFallback: String {
    label.trimmedForCommandDisplay(ifEmpty: "label")
  }

  var refreshScopeTitle: String {
    switch refreshScope {
    case "mobileMirror": "mobile mirror"
    case "reviews": "reviews"
    case "taskBoard": "task board"
    case "sessionTasks": "session tasks"
    default: "station health"
    }
  }

  var reviewTitleOrFallback: String {
    if let review = selectedReview {
      return "#\(review.number)"
    }
    if !repository.trimmedForCommand.isEmpty, !reviewNumber.trimmedForCommand.isEmpty {
      return "#\(reviewNumber.trimmedForCommand)"
    }
    return "selected PR"
  }

  func makeDraft() -> MobileCommandDraft {
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
      payload: payload
    )
  }

  var selectedReview: MobileReviewSummary? {
    store.snapshot.reviews.first { $0.id == reviewID && $0.stationID == effectiveStationID }
  }

  var selectedTask: MobileTaskBoardSummary? {
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
        auditReason: auditReason.trimmedCommandValue
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
        status: taskStatus
      )
      draft.payload["dryRun"] = dryRun ? "true" : "false"
      return draft
    case .taskBoardPlanApproval:
      return task.commandDraft(
        kind: .taskBoardPlanApproval,
        targetRevision: store.snapshot.revision
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
      payload["dryRun"] = dryRun ? "true" : "false"
    case .taskBoardPlanApproval, .agentStop, .pullRequestApprove, .pullRequestRerunChecks:
      break
    case .agentStart:
      payload["agent"] = agent
      payload["role"] = role
      payload["prompt"] = prompt
    case .agentPrompt:
      payload["prompt"] = prompt
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

  func submit() async {
    submitting = true
    defer { submitting = false }
    await store.queueCommand(makeDraft())
    dismiss()
  }

  func seedStationIfNeeded() {
    guard stationID.isEmpty else {
      return
    }
    stationID =
      store.selectedStationID.isEmpty
      ? store.snapshot.stations.first?.id ?? ""
      : store.selectedStationID
  }

  func seedDefaultsForKind() {
    if kind == .agentStart, agent.trimmedForCommand.isEmpty {
      agent = "codex"
    }
    if kind == .refresh, refreshScope.trimmedForCommand.isEmpty {
      refreshScope = "health"
    }
    if kind == .taskBoardDispatch || kind == .taskBoardPlanApproval, taskID.isEmpty {
      taskID = taskBoardItemsForStation.first(where: \.needsYou)?.id ?? ""
    }
    if isPullRequestCommand(kind), reviewID.isEmpty {
      reviewID = reviewsForStation.first(where: \.needsYou)?.id ?? ""
    }
  }

  func isPullRequestCommand(_ kind: MobileCommandKind) -> Bool {
    switch kind {
    case .pullRequestApprove, .pullRequestLabel, .pullRequestRerunChecks, .pullRequestMerge:
      true
    default:
      false
    }
  }

  func clearForeignSelections() {
    if !sessionsForStation.contains(where: { $0.id == sessionID }) {
      sessionID = ""
    }
    if !reviewsForStation.contains(where: { $0.id == reviewID }) {
      reviewID = ""
    }
    if !taskBoardItemsForStation.contains(where: { $0.id == taskID }) {
      taskID = ""
    }
  }
}

extension String {
  fileprivate var trimmedForCommand: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate var trimmedCommandValue: String? {
    let value = trimmedForCommand
    return value.isEmpty ? nil : value
  }

  fileprivate func trimmedForCommandDisplay(ifEmpty fallback: String) -> String {
    let value = trimmedForCommand
    return value.isEmpty ? fallback : value
  }
}
