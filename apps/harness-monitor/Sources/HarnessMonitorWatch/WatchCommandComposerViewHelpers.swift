import HarnessMonitorCore
import SwiftUI

extension WatchCommandComposerView {
  var effectiveStationID: String {
    stationID.isEmpty ? store.snapshot.stations.first?.id ?? "" : stationID
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
        return "Station is not paired."
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
    switch kind {
    case .acpPermissionDecision:
      "\(acpDecision == "deny_all" ? "Deny" : "Approve") permission for \(agentDisplay)."
    case .taskBoardDispatch:
      "Dispatch task board work."
    case .taskBoardPlanApproval:
      "Approve plan \(taskDisplay)."
    case .agentStart:
      "Start \(agent.trimmedDisplay(fallback: "agent")) in \(sessionDisplay)."
    case .agentStop:
      "Stop \(agentDisplay)."
    case .agentPrompt:
      "Prompt \(agentDisplay)."
    case .pullRequestApprove:
      "Approve \(reviewDisplay)."
    case .pullRequestLabel:
      "Label \(reviewDisplay)."
    case .pullRequestRerunChecks:
      "Rerun checks for \(reviewDisplay)."
    case .pullRequestMerge:
      "Merge \(reviewDisplay) with \(mergeMethod)."
    case .refresh:
      "Refresh \(refreshScopeDisplay)."
    }
  }

  var agentDisplay: String {
    agentID.trimmedDisplay(fallback: "agent")
  }

  var taskDisplay: String {
    taskID.trimmedDisplay(fallback: "task")
  }

  var sessionDisplay: String {
    sessionID.trimmedDisplay(fallback: "session")
  }

  var reviewDisplay: String {
    if let review = selectedReview {
      return "#\(review.number)"
    }
    if !reviewNumber.trimmedForWatchCommand.isEmpty {
      return "#\(reviewNumber.trimmedForWatchCommand)"
    }
    return "PR"
  }

  var refreshScopeDisplay: String {
    switch refreshScope {
    case "mobileMirror": "mirror"
    case "reviews": "reviews"
    case "taskBoard": "task board"
    case "sessionTasks": "session tasks"
    default: "health"
    }
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
      sessionID: sessionID.trimmedWatchCommandValue,
      agentID: agentID.trimmedWatchCommandValue,
      reviewID: reviewID.trimmedWatchCommandValue,
      taskID: taskID.trimmedWatchCommandValue,
      targetRevision: store.snapshot.revision
    )
    return MobileCommandDraft(
      kind: kind,
      confirmationText: confirmationText,
      auditReason: auditReason.trimmedWatchCommandValue,
      target: target,
      payload: payload,
      expiresAfter: 10 * 60
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
        auditReason: auditReason.trimmedWatchCommandValue,
        expiresAfter: 10 * 60
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
      return task.commandDraft(
        kind: .taskBoardDispatch,
        targetRevision: store.snapshot.revision,
        status: taskStatus,
        expiresAfter: 10 * 60
      )
    case .taskBoardPlanApproval:
      return task.commandDraft(
        kind: .taskBoardPlanApproval,
        targetRevision: store.snapshot.revision,
        expiresAfter: 10 * 60
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
    case .taskBoardPlanApproval, .agentStop, .pullRequestApprove, .pullRequestRerunChecks:
      break
    case .agentStart:
      payload["agent"] = agent
      payload["role"] = role
      payload["prompt"] = promptText
    case .agentPrompt:
      payload["prompt"] = promptText
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

  var promptText: String {
    if let customPrompt = prompt.trimmedWatchCommandValue {
      return customPrompt
    }
    switch promptPreset {
    case "summarize":
      return "Summarize the current blocker and next action."
    case "tests":
      return "Run the focused validation for your current task and report failures."
    case "handoff":
      return "Prepare a concise handoff with current status, risks, and next steps."
    default:
      return "Continue with the current task and report the next concrete result."
    }
  }

  func addManualReviewPayload(to payload: inout [String: String]) {
    if let repository = repository.trimmedWatchCommandValue {
      payload["repository"] = repository
    }
    if let reviewNumber = reviewNumber.trimmedWatchCommandValue {
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
    if kind == .agentStart, agent.trimmedForWatchCommand.isEmpty {
      agent = "codex"
    }
    if kind == .pullRequestMerge, auditReason.trimmedForWatchCommand.isEmpty {
      auditReason = "Confirmed from Apple Watch."
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
  fileprivate var trimmedForWatchCommand: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate var trimmedWatchCommandValue: String? {
    let value = trimmedForWatchCommand
    return value.isEmpty ? nil : value
  }

  fileprivate func trimmedDisplay(fallback: String) -> String {
    let value = trimmedForWatchCommand
    return value.isEmpty ? fallback : value
  }
}
