import Foundation
import HarnessMonitorCore

/// Validation outcome the composer views map to their own copy. The draft-invalid
/// case carries the thrown error's text (shared); station-not-paired is mapped to
/// per-platform wording by each view.
public enum CommandFormValidationError: Equatable, Sendable {
  case invalidDraft(String)
  case stationNotPaired
}

extension CommandFormModel {
  public var effectiveStationID: String {
    if !stationID.isEmpty {
      return stationID
    }
    return store.snapshot.stations.first?.id ?? ""
  }

  public var sessionsForStation: [MobileSessionSummary] {
    store.snapshot.sessions
      .filter { $0.stationID == effectiveStationID }
      .sorted { $0.lastActivityAt > $1.lastActivityAt }
  }

  public var reviewsForStation: [MobileReviewSummary] {
    store.snapshot.reviews
      .filter { $0.stationID == effectiveStationID }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  public var taskBoardItemsForStation: [MobileTaskBoardSummary] {
    store.snapshot.taskBoardItems(for: effectiveStationID)
  }

  /// `validate()` requires a non-empty confirmation text, so a placeholder stands
  /// in here: validation only checks emptiness, and the real submit text (built by
  /// the view) is always a non-empty sentence, so the outcome is identical.
  public var validationError: CommandFormValidationError? {
    do {
      try makeDraft(confirmationText: "Confirm").validate()
      if !store.canQueueCommand(stationID: effectiveStationID) {
        return .stationNotPaired
      }
      return nil
    } catch {
      return .invalidDraft(String(describing: error))
    }
  }

  public var canSubmit: Bool {
    !submitting && validationError == nil
  }

  /// The prompt actually sent: on platforms that resolve presets (watch), a blank
  /// custom prompt falls back to the selected preset's text; otherwise the raw
  /// prompt is used as typed (iPhone).
  public var resolvedPrompt: String {
    guard profile.resolvesPromptPresets else {
      return prompt
    }
    let trimmed = prompt.trimmedForCommand
    if !trimmed.isEmpty {
      return trimmed
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

  public func isPullRequestCommand(_ kind: MobileCommandKind) -> Bool {
    switch kind {
    case .pullRequestApprove, .pullRequestLabel, .pullRequestRerunChecks, .pullRequestMerge:
      true
    default:
      false
    }
  }

  public func seedStationIfNeeded() {
    guard stationID.isEmpty else {
      return
    }
    stationID =
      store.selectedStationID.isEmpty
      ? store.snapshot.stations.first?.id ?? ""
      : store.selectedStationID
  }

  public func seedDefaultsForKind() {
    if kind == .agentStart, agent.trimmedForCommand.isEmpty {
      agent = "codex"
    }
    if kind == .refresh, refreshScope.trimmedForCommand.isEmpty {
      refreshScope = "health"
    }
    if profile.seedsMergeAuditReason, kind == .pullRequestMerge,
      auditReason.trimmedForCommand.isEmpty
    {
      auditReason = profile.mergeAuditReason
    }
    if kind == .taskBoardDispatch || kind == .taskBoardPlanApproval, taskID.isEmpty {
      taskID = taskBoardItemsForStation.first(where: \.needsYou)?.id ?? ""
    }
    if isPullRequestCommand(kind), reviewID.isEmpty {
      reviewID = reviewsForStation.first(where: \.needsYou)?.id ?? ""
    }
  }

  public func clearForeignSelections() {
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
  var trimmedForCommand: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedCommandValue: String? {
    let value = trimmedForCommand
    return value.isEmpty ? nil : value
  }
}
