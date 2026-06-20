import HarnessMonitorPolicyModels

/// Three-state value for an optional `Bool` evidence field: unset (the daemon
/// treats it as unknown), yes, or no. Backs a segmented control so the user can
/// leave evidence unspecified rather than being forced to true/false.
enum ScenarioTriState: String, CaseIterable, Identifiable {
  case unset
  case yes
  case no

  var id: String { rawValue }

  var label: String {
    switch self {
    case .unset: return "Any"
    case .yes: return "Yes"
    case .no: return "No"
    }
  }

  var boolValue: Bool? {
    switch self {
    case .unset: return nil
    case .yes: return true
    case .no: return false
    }
  }

  init(_ value: Bool?) {
    switch value {
    case .none: self = .unset
    case .some(true): self = .yes
    case .some(false): self = .no
    }
  }
}

/// Mutable form state for the scenario editor. Holds every `PolicyInput` field as
/// an editor-friendly type (strings for optionals, tri-states for optional bools)
/// and maps both directions, so the sheet owns a value-type draft and never binds
/// the wire model directly. Numbers parse leniently: a blank or invalid field
/// becomes `nil`.
struct PolicyCanvasScenarioEditorDraft {
  var name: String = ""
  var workflow: String = ""
  var action: PolicyAction = .mergePr

  var repository: String = ""
  var branch: String = ""
  var pullRequest: String = ""
  var taskBoardItemId: String = ""
  var sessionId: String = ""
  var agentId: String = ""
  var paths: String = ""

  var checksGreen: ScenarioTriState = .unset
  var branchProtectionAllowsMerge: ScenarioTriState = .unset
  var reviewerVerdictApproved: ScenarioTriState = .unset
  var unresolvedRequestedChanges: String = ""
  var protectedPathTouched: ScenarioTriState = .unset
  var riskScore: String = ""
  var reviewIsOpen: ScenarioTriState = .unset
  var reviewIsDraft: ScenarioTriState = .unset
  var reviewReviewRequired: ScenarioTriState = .unset
  var reviewHasNoDecision: ScenarioTriState = .unset
  var reviewHasMergeConflicts: ScenarioTriState = .unset
  var reviewPolicyBlocked: ScenarioTriState = .unset
  var reviewViewerCanUpdate: ScenarioTriState = .unset

  init() {}

  init(name: String, input: PolicyInput) {
    self.name = name
    self.workflow = input.workflow ?? ""
    self.action = input.action
    let subject = input.subject
    self.repository = subject.repository ?? ""
    self.branch = subject.branch ?? ""
    self.pullRequest = subject.pullRequest ?? ""
    self.taskBoardItemId = subject.taskBoardItemId ?? ""
    self.sessionId = subject.sessionId ?? ""
    self.agentId = subject.agentId ?? ""
    self.paths = subject.paths.joined(separator: "\n")
    let evidence = input.evidence
    self.checksGreen = ScenarioTriState(evidence.checksGreen)
    self.branchProtectionAllowsMerge = ScenarioTriState(evidence.branchProtectionAllowsMerge)
    self.reviewerVerdictApproved = ScenarioTriState(evidence.reviewerVerdictApproved)
    self.unresolvedRequestedChanges = evidence.unresolvedRequestedChanges.map(String.init) ?? ""
    self.protectedPathTouched = ScenarioTriState(evidence.protectedPathTouched)
    self.riskScore = evidence.riskScore.map(String.init) ?? ""
    self.reviewIsOpen = ScenarioTriState(evidence.reviewIsOpen)
    self.reviewIsDraft = ScenarioTriState(evidence.reviewIsDraft)
    self.reviewReviewRequired = ScenarioTriState(evidence.reviewReviewRequired)
    self.reviewHasNoDecision = ScenarioTriState(evidence.reviewHasNoDecision)
    self.reviewHasMergeConflicts = ScenarioTriState(evidence.reviewHasMergeConflicts)
    self.reviewPolicyBlocked = ScenarioTriState(evidence.reviewPolicyBlocked)
    self.reviewViewerCanUpdate = ScenarioTriState(evidence.reviewViewerCanUpdate)
  }

  var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func resolvedInput() -> PolicyInput {
    PolicyInput(
      workflow: Self.nilIfBlank(workflow),
      action: action,
      subject: PolicySubject(
        taskBoardItemId: Self.nilIfBlank(taskBoardItemId),
        sessionId: Self.nilIfBlank(sessionId),
        agentId: Self.nilIfBlank(agentId),
        repository: Self.nilIfBlank(repository),
        branch: Self.nilIfBlank(branch),
        pullRequest: Self.nilIfBlank(pullRequest),
        paths: Self.lines(paths)
      ),
      evidence: PolicyEvidence(
        checksGreen: checksGreen.boolValue,
        branchProtectionAllowsMerge: branchProtectionAllowsMerge.boolValue,
        reviewerVerdictApproved: reviewerVerdictApproved.boolValue,
        unresolvedRequestedChanges: Self.uint32(unresolvedRequestedChanges),
        protectedPathTouched: protectedPathTouched.boolValue,
        riskScore: Self.uint8(riskScore),
        reviewIsOpen: reviewIsOpen.boolValue,
        reviewIsDraft: reviewIsDraft.boolValue,
        reviewReviewRequired: reviewReviewRequired.boolValue,
        reviewHasNoDecision: reviewHasNoDecision.boolValue,
        reviewHasMergeConflicts: reviewHasMergeConflicts.boolValue,
        reviewPolicyBlocked: reviewPolicyBlocked.boolValue,
        reviewViewerCanUpdate: reviewViewerCanUpdate.boolValue
      )
    )
  }

  private static func nilIfBlank(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func lines(_ value: String) -> [String] {
    value
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private static func uint32(_ value: String) -> UInt32? {
    UInt32(value.trimmingCharacters(in: .whitespaces))
  }

  private static func uint8(_ value: String) -> UInt8? {
    UInt8(value.trimmingCharacters(in: .whitespaces))
  }
}
