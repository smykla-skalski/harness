import Foundation

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
      "Choose a station."
    case .missingTarget(let field):
      "Enter \(field)."
    case .missingPayload(let field):
      "Enter \(field)."
    case .missingConfirmationText:
      "Enter confirmation text."
    case .missingAuditReason:
      "Enter an audit reason for this destructive command."
    case .invalidPayload(let key, let value):
      "\(key) has unsupported value \(value)."
    }
  }
}

public enum MobileCommandRetryError: Error, Equatable, CustomStringConvertible, Sendable {
  case notRetryable(status: MobileCommandStatus)

  public var description: String {
    switch self {
    case .notRetryable(let status):
      "Only failed or expired commands can be retried safely; current status is \(status.title)."
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
    switch kind {
    case .pullRequestMerge:
      .destructive
    case .pullRequestRerunChecks, .refresh:
      .low
    case .acpPermissionDecision, .taskBoardDispatch, .taskBoardPlanApproval, .agentStart,
      .agentStop, .agentPrompt, .pullRequestApprove, .pullRequestLabel:
      .high
    }
  }

  public func makeCommand(
    id: String,
    actorDeviceID: String = "",
    createdAt: Date,
    expiresAt: Date? = nil
  ) throws -> MobileCommandRecord {
    try validate()
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
    guard !trimmed(target.stationID).isEmpty else {
      throw MobileCommandDraftValidationError.missingStation
    }
    guard !trimmed(confirmationText).isEmpty else {
      throw MobileCommandDraftValidationError.missingConfirmationText
    }
    if risk == .destructive, trimmedAuditReason == nil {
      throw MobileCommandDraftValidationError.missingAuditReason
    }
    try validateKindSpecificRequirements()
  }

  private func validateKindSpecificRequirements() throws {
    switch kind {
    case .acpPermissionDecision:
      try validateAcpPermissionDecision()
    case .taskBoardDispatch:
      try validateTaskBoardDispatch()
    case .taskBoardPlanApproval:
      try requireTarget(target.taskID, named: "task ID")
    case .agentStart:
      try validateAgentStart()
    case .agentStop:
      try requireTarget(target.agentID, named: "agent ID")
    case .agentPrompt:
      try validateAgentPrompt()
    case .pullRequestApprove, .pullRequestRerunChecks, .pullRequestMerge:
      try requireReviewReference()
    case .pullRequestLabel:
      try validatePullRequestLabel()
    case .refresh:
      try validateRefresh()
    }
  }

  private func validateAcpPermissionDecision() throws {
    try requireTarget(target.agentID, named: "agent ID")
    try requirePayload("batchID", named: "batch ID")
    let decision = try requirePayload("decision", named: "decision")
    guard ["approve_all", "deny_all", "approve_some"].contains(decision) else {
      throw MobileCommandDraftValidationError.invalidPayload(key: "decision", value: decision)
    }
  }

  private func validateTaskBoardDispatch() throws {
    if let status = payloadValue("status"), !knownTaskBoardStatuses.contains(status) {
      throw MobileCommandDraftValidationError.invalidPayload(key: "status", value: status)
    }
  }

  private func validateAgentStart() throws {
    try requireTarget(target.sessionID, named: "session ID")
    try requirePayload("agent", named: "agent")
  }

  private func validateAgentPrompt() throws {
    try requireTarget(target.agentID, named: "agent ID")
    try requirePayload("prompt", named: "prompt")
  }

  private func validatePullRequestLabel() throws {
    try requireReviewReference()
    try requirePayload("label", named: "label")
  }

  private func validateRefresh() throws {
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
      let value = trimmed(pair.value)
      if !value.isEmpty {
        result[pair.key] = value
      }
    }
  }

  private var trimmedAuditReason: String? {
    let value = auditReason.map(trimmed) ?? ""
    return value.isEmpty ? nil : value
  }

  private var knownTaskBoardStatuses: Set<String> {
    [
      "new", "planning", "plan_review", "needs_you", "todo", "in_progress", "in_review",
      "done", "blocked",
    ]
  }

  private var knownRefreshScopes: Set<String> {
    ["health", "mobileMirror", "reviews", "taskBoard", "sessionTasks"]
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

  private func requireReviewReference() throws {
    if let reviewID = target.reviewID, !trimmed(reviewID).isEmpty {
      return
    }
    guard payloadValue("repository") != nil, payloadValue("number") != nil else {
      throw MobileCommandDraftValidationError.missingTarget("pull request")
    }
  }

  private func payloadValue(_ key: String) -> String? {
    guard let value = payload[key].map(trimmed), !value.isEmpty else {
      return nil
    }
    return value
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
