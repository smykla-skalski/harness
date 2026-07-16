import Foundation

private func canonicalTaskBoardDispatchStatus(_ status: String) -> String {
  switch status {
  case "new":
    "todo"
  case "plan_review":
    "agentic_review"
  case "needs_you":
    "human_required"
  case "blocked":
    "failed"
  default:
    status
  }
}

public enum MobileCommandDraftValidationError: Error, Equatable, CustomStringConvertible, Sendable {
  case missingStation
  case missingTarget(String)
  case missingPayload(String)
  case missingConfirmationText
  case missingAuditReason
  case invalidPayload(key: String, value: String)

  public var description: String {
    switch self {
    case .missingStation:
      String(localized: "Choose a station", bundle: .module)
    case .missingTarget(let field):
      String(localized: "Enter \(field)", bundle: .module)
    case .missingPayload(let field):
      String(localized: "Enter \(field)", bundle: .module)
    case .missingConfirmationText:
      String(localized: "Enter confirmation text", bundle: .module)
    case .missingAuditReason:
      String(localized: "Enter an audit reason for this destructive command", bundle: .module)
    case .invalidPayload(let key, let value):
      String(localized: "\(key) has unsupported value \(value)", bundle: .module)
    }
  }
}

public enum MobileCommandRetryError: Error, Equatable, CustomStringConvertible, Sendable {
  case notRetryable(status: MobileCommandStatus)

  public var description: String {
    switch self {
    case .notRetryable(let status):
      String(
        localized:
          "Only failed or expired commands can be retried safely; current status is \(status.title)",
        bundle: .module
      )
    }
  }
}

public struct MobileCommandDraft: Equatable, Sendable {
  public var kind: MobileCommandKind
  public var title: String
  public var confirmationText: String
  public var auditReason: String?
  public var target: MobileCommandTarget
  public var payload: [String: String]
  public var expiresAfter: TimeInterval

  public init(
    kind: MobileCommandKind,
    title: String? = nil,
    confirmationText: String,
    auditReason: String? = nil,
    target: MobileCommandTarget,
    payload: [String: String] = [:],
    expiresAfter: TimeInterval = 15 * 60
  ) {
    self.kind = kind
    self.title = title ?? kind.title
    self.confirmationText = confirmationText
    self.auditReason = auditReason
    self.target = target
    self.payload = payload
    self.expiresAfter = expiresAfter
  }

  public var risk: MobileCommandRisk {
    kind.risk
  }

  public func makeCommand(
    id: String,
    actorDeviceID: String = "",
    createdAt: Date,
    expiresAt: Date? = nil
  ) throws -> MobileCommandRecord {
    try validate()
    let target = trimmedTarget
    return MobileCommandRecord(
      id: id,
      stationID: target.stationID,
      kind: kind,
      risk: risk,
      status: .draft,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      confirmationText: confirmationText.trimmingCharacters(in: .whitespacesAndNewlines),
      auditReason: trimmedAuditReason,
      target: target,
      payload: trimmedPayload,
      actorDeviceID: actorDeviceID,
      createdAt: createdAt,
      expiresAt: expiresAt ?? createdAt.addingTimeInterval(expiresAfter),
      updatedAt: createdAt
    )
  }

  public func validate() throws {
    let target = trimmedTarget
    try validateExpiration()
    guard !trimmed(target.stationID).isEmpty else {
      throw MobileCommandDraftValidationError.missingStation
    }
    guard !trimmed(confirmationText).isEmpty else {
      throw MobileCommandDraftValidationError.missingConfirmationText
    }
    if risk == .destructive, trimmedAuditReason == nil {
      throw MobileCommandDraftValidationError.missingAuditReason
    }
    try validateKindSpecificRequirements(target: target)
  }

  private func validateKindSpecificRequirements(target: MobileCommandTarget) throws {
    switch kind {
    case .acpPermissionDecision:
      try validateAcpPermissionDecision(target: target)
    case .taskBoardDispatch:
      try validateTaskBoardDispatch(target: target)
    case .taskBoardPlanApproval:
      try requireTarget(target.taskID, named: "task ID")
    case .agentStart:
      try validateAgentStart(target: target)
    case .agentStop:
      try requireTarget(target.agentID, named: "agent ID")
    case .agentPrompt:
      try validateAgentPrompt(target: target)
    case .pullRequestApprove, .pullRequestRerunChecks, .pullRequestMerge:
      try requireReviewReference(target: target)
      if kind == .pullRequestMerge {
        try validateKnownPayload("method", values: knownMergeMethods)
      }
    case .pullRequestLabel:
      try validatePullRequestLabel(target: target)
    case .refresh:
      try validateRefresh(target: target)
    }
  }

  private func validateAcpPermissionDecision(target: MobileCommandTarget) throws {
    try requireTarget(target.agentID, named: "agent ID")
    try requirePayload("batchID", named: "batch ID")
    let decision = try requirePayload("decision", named: "decision")
    guard ["approve_all", "deny_all", "approve_some"].contains(decision) else {
      throw MobileCommandDraftValidationError.invalidPayload(key: "decision", value: decision)
    }
    if decision == "approve_some", csvPayload("requestIDs").isEmpty {
      throw MobileCommandDraftValidationError.missingPayload("request IDs")
    }
  }

  private func validateTaskBoardDispatch(target: MobileCommandTarget) throws {
    if let status = payloadValue("status"), !knownTaskBoardStatuses.contains(status) {
      throw MobileCommandDraftValidationError.invalidPayload(key: "status", value: status)
    }
    if target.taskID == nil, payloadValue("itemID") == nil {
      throw MobileCommandDraftValidationError.missingTarget("task ID")
    }
    try validateBoolPayload("dryRun")
  }

  private func validateAgentStart(target: MobileCommandTarget) throws {
    try requireTarget(target.sessionID, named: "session ID")
    try requirePayload("agent", named: "agent")
    try validateBoolPayload("allowCustomModel")
    try validateBoolPayload("recordPermissions")
    try validatePositiveIntPayload("rows")
    try validatePositiveIntPayload("cols")
    try validateKnownPayload("role", values: knownAgentRoles)
    try validateKnownPayload("fallbackRole", values: knownAgentRoles)
    try validateKnownPayload("family", values: knownAgentFamilies)
    try validateKnownPayload("mode", values: knownCodexModes)
  }

  private func validateAgentPrompt(target: MobileCommandTarget) throws {
    try requireTarget(target.agentID, named: "agent ID")
    try requirePayload("prompt", named: "prompt")
  }

  private func validatePullRequestLabel(target: MobileCommandTarget) throws {
    try requireReviewReference(target: target)
    try requirePayload("label", named: "label")
  }

  private func validateRefresh(target: MobileCommandTarget) throws {
    let scope = payloadValue("scope") ?? "health"
    guard knownRefreshScopes.contains(scope) else {
      throw MobileCommandDraftValidationError.invalidPayload(key: "scope", value: scope)
    }
    if scope == "sessionTasks" {
      try requireTarget(target.sessionID, named: "session ID")
    }
  }

  private var trimmedPayload: [String: String] {
    payload.reduce(into: [:]) { result, pair in
      let key = trimmed(pair.key)
      let value = trimmed(pair.value)
      if !key.isEmpty, !value.isEmpty {
        result[key] =
          kind == .taskBoardDispatch && key == "status"
          ? canonicalTaskBoardDispatchStatus(value)
          : value
      }
    }
  }

  private var trimmedTarget: MobileCommandTarget {
    MobileCommandTarget(
      stationID: trimmed(target.stationID),
      sessionID: trimmedOptional(target.sessionID),
      agentID: trimmedOptional(target.agentID),
      reviewID: trimmedOptional(target.reviewID),
      taskID: trimmedOptional(target.taskID),
      targetRevision: target.targetRevision
    )
  }

  private var trimmedAuditReason: String? {
    let value = auditReason.map(trimmed) ?? ""
    return value.isEmpty ? nil : value
  }

  private var knownTaskBoardStatuses: Set<String> {
    [
      "backlog", "todo", "planning", "in_progress", "agentic_review", "testing", "in_review",
      "to_review", "human_required", "failed", "done",
    ]
  }

  private var knownRefreshScopes: Set<String> {
    ["health", "mobileMirror", "reviews", "taskBoard", "sessionTasks"]
  }

  private var knownAgentRoles: Set<String> {
    ["leader", "observer", "worker", "reviewer", "improver"]
  }

  private var knownAgentFamilies: Set<String> {
    ["terminal", "codex", "acp"]
  }

  private var knownCodexModes: Set<String> {
    ["report", "workspace_write", "approval"]
  }

  private var knownMergeMethods: Set<String> {
    ["squash", "merge", "rebase"]
  }

  private func requireTarget(_ value: String?, named name: String) throws {
    guard let value, !trimmed(value).isEmpty else {
      throw MobileCommandDraftValidationError.missingTarget(name)
    }
  }

  @discardableResult
  private func requirePayload(_ key: String, named name: String) throws -> String {
    guard let value = payloadValue(key) else {
      throw MobileCommandDraftValidationError.missingPayload(name)
    }
    return value
  }

  private func requireReviewReference(target: MobileCommandTarget) throws {
    if target.reviewID != nil {
      return
    }
    guard payloadValue("repository") != nil, let number = payloadValue("number") else {
      throw MobileCommandDraftValidationError.missingTarget("pull request")
    }
    guard let parsedNumber = UInt64(number), parsedNumber > 0 else {
      throw MobileCommandDraftValidationError.invalidPayload(key: "number", value: number)
    }
  }

  private func payloadValue(_ key: String) -> String? {
    guard let value = trimmedPayload[key] else {
      return nil
    }
    return value
  }

  private func validateExpiration() throws {
    guard expiresAfter.isFinite, expiresAfter > 0 else {
      throw MobileCommandDraftValidationError.invalidPayload(
        key: "expiresAfter",
        value: String(expiresAfter)
      )
    }
  }

  private func validateBoolPayload(_ key: String) throws {
    guard let value = payloadValue(key) else {
      return
    }
    switch value.lowercased() {
    case "1", "true", "yes", "0", "false", "no":
      return
    default:
      throw MobileCommandDraftValidationError.invalidPayload(key: key, value: value)
    }
  }

  private func validatePositiveIntPayload(_ key: String) throws {
    guard let value = payloadValue(key) else {
      return
    }
    guard let intValue = Int(value), intValue > 0 else {
      throw MobileCommandDraftValidationError.invalidPayload(key: key, value: value)
    }
  }

  private func validateKnownPayload(_ key: String, values: Set<String>) throws {
    guard let value = payloadValue(key) else {
      return
    }
    guard values.contains(value) else {
      throw MobileCommandDraftValidationError.invalidPayload(key: key, value: value)
    }
  }

  private func csvPayload(_ key: String) -> [String] {
    payloadValue(key)?
      .split(separator: ",")
      .map { trimmed(String($0)) }
      .filter { !$0.isEmpty }
      ?? []
  }

  private func trimmedOptional(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmedValue = trimmed(value)
    return trimmedValue.isEmpty ? nil : trimmedValue
  }

  private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension MobileCommandRecord {
  public var canRetrySafely: Bool {
    status == .failed || status == .expired
  }

  public func retryDraft(
    currentRevision: Int64,
    expiresAfter: TimeInterval = 15 * 60
  ) throws -> MobileCommandDraft {
    guard canRetrySafely else {
      throw MobileCommandRetryError.notRetryable(status: status)
    }
    var retryTarget = target
    retryTarget.targetRevision = currentRevision
    return MobileCommandDraft(
      kind: kind,
      title: title,
      confirmationText: confirmationText,
      auditReason: auditReason,
      target: retryTarget,
      payload: payload,
      expiresAfter: expiresAfter
    )
  }
}
