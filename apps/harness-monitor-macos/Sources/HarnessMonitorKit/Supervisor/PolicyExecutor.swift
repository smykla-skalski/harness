import Foundation

// MARK: - Protocols

/// Narrow API surface the `PolicyExecutor` uses to call the daemon. A fake implementation is
/// provided by tests; the real `HarnessMonitorAPIClient` conforms via an extension.
public protocol SupervisorAPIClient: Sendable {
  func nudgeAgent(agentID: String, input: String) async throws
  func assignTask(taskID: String, agentID: String) async throws
  func dropTask(taskID: String, reason: String) async throws
  func postNotification(
    ruleID: String,
    severity: DecisionSeverity,
    summary: String,
    decisionID: String?
  ) async
}

/// One persisted record written to the supervisor audit trail.
public struct SupervisorAuditRecord: Sendable {
  public let id: String
  public let tickID: String
  public let kind: String
  public let ruleID: String?
  public let severity: DecisionSeverity?
  public let payloadJSON: String
  public let createdAt: Date

  public init(
    id: String,
    tickID: String,
    kind: String,
    ruleID: String?,
    severity: DecisionSeverity?,
    payloadJSON: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.tickID = tickID
    self.kind = kind
    self.ruleID = ruleID
    self.severity = severity
    self.payloadJSON = payloadJSON
    self.createdAt = createdAt
  }
}

/// Receives `SupervisorAuditRecord`s in the order they are produced. Used by `PolicyExecutor`
/// to record `actionDispatched` / `actionExecuted` / `actionFailed` events.
public protocol SupervisorAuditWriter: Sendable {
  func append(_ record: SupervisorAuditRecord) async
}

// MARK: - PolicyExecutor

/// Bridges `PolicyAction`s from rules to the daemon API and to `DecisionStore`. Enforces
/// audit-before-action ordering and sliding-window deduplication keyed by `actionKey`.
public actor PolicyExecutor {
  private let api: any SupervisorAPIClient
  private let decisions: DecisionStore
  private let audit: any SupervisorAuditWriter
  private let cooldown: TimeInterval

  /// Keys of actions dispatched within the current cooldown window, mapped to the timestamp.
  private var recentKeys: [String: Date] = [:]

  public init(
    api: any SupervisorAPIClient,
    decisions: DecisionStore,
    audit: any SupervisorAuditWriter,
    cooldown: TimeInterval = 60
  ) {
    self.api = api
    self.decisions = decisions
    self.audit = audit
    self.cooldown = cooldown
  }

  /// Executes one `PolicyAction`, enforcing audit ordering and dedup.
  ///
  /// Ordering invariant: `actionDispatched` is written before the action fires.
  /// `actionExecuted` or `actionFailed` is written after the action completes.
  public func execute(_ action: PolicyAction, tickID: String? = nil) async -> PolicyOutcome {
    let key = action.actionKey
    pruneExpiredKeys()

    if recentKeys[key] != nil {
      return .skippedDuplicate(actionKey: key)
    }

    let dispatchRecord = auditRecord(
      id: UUID().uuidString,
      kind: "actionDispatched",
      action: action,
      tickID: tickID ?? action.auditTickID
    )
    await audit.append(dispatchRecord)
    recentKeys[key] = Date()

    do {
      try await dispatch(action)
      let executedRecord = auditRecord(
        id: UUID().uuidString,
        kind: "actionExecuted",
        action: action,
        tickID: tickID ?? action.auditTickID
      )
      await audit.append(executedRecord)
      return .executed(actionKey: key)
    } catch {
      let sanitizedError = redactSupervisorErrorMessage(error.localizedDescription)
      HarnessMonitorLogger.supervisorWarning(
        "action failed key=\(key) error=\(sanitizedError)"
      )
      let failedRecord = auditRecord(
        id: UUID().uuidString,
        kind: "actionFailed",
        action: action,
        tickID: tickID ?? action.auditTickID
      )
      await audit.append(failedRecord)
      return .failed(actionKey: key, error: sanitizedError)
    }
  }

  // MARK: - Private helpers

  private func pruneExpiredKeys() {
    let cutoff = Date().addingTimeInterval(-cooldown)
    recentKeys = recentKeys.filter { $0.value > cutoff }
  }

  private func auditRecord(
    id: String,
    kind: String,
    action: PolicyAction,
    tickID: String
  ) -> SupervisorAuditRecord {
    SupervisorAuditRecord(
      id: id,
      tickID: tickID,
      kind: kind,
      ruleID: ruleID(for: action),
      severity: severity(for: action),
      payloadJSON: actionPayloadJSON(action)
    )
  }

  private func dispatch(_ action: PolicyAction) async throws {
    switch action {
    case .nudgeAgent(let payload):
      try await api.nudgeAgent(agentID: payload.agentID, input: payload.prompt)

    case .assignTask(let payload):
      try await api.assignTask(taskID: payload.taskID, agentID: payload.agentID)

    case .dropTask(let payload):
      try await api.dropTask(taskID: payload.taskID, reason: payload.reason)

    case .queueDecision(let payload):
      let exists = try await decisions.decision(id: payload.id) != nil
      let draft = DecisionDraft(
        id: payload.id,
        severity: payload.severity,
        ruleID: payload.ruleID,
        sessionID: payload.sessionID,
        agentID: payload.agentID,
        taskID: payload.taskID,
        summary: payload.summary,
        contextJSON: payload.contextJSON,
        suggestedActionsJSON: payload.suggestedActionsJSON
      )
      if !exists {
        try await decisions.insert(draft)
        await api.postNotification(
          ruleID: payload.ruleID,
          severity: payload.severity,
          summary: payload.summary,
          decisionID: payload.id
        )
      }

    case .notifyOnly(let payload):
      await api.postNotification(
        ruleID: payload.ruleID,
        severity: payload.severity,
        summary: payload.summary,
        decisionID: nil
      )

    case .logEvent(let payload):
      HarnessMonitorLogger.supervisorTrace("logEvent: \(payload.message)")

    case .suggestConfigChange(let payload):
      HarnessMonitorLogger.supervisorTrace(
        """
        suggestConfigChange ruleID=\(payload.ruleID) \
        rationale=\(payload.rationale)
        """
      )
    }
  }

  private func ruleID(for action: PolicyAction) -> String? {
    switch action {
    case .nudgeAgent(let payload): payload.ruleID
    case .assignTask(let payload): payload.ruleID
    case .dropTask(let payload): payload.ruleID
    case .queueDecision(let payload): payload.ruleID
    case .notifyOnly(let payload): payload.ruleID
    case .logEvent(let payload): payload.ruleID
    case .suggestConfigChange(let payload): payload.ruleID
    }
  }

  private func severity(for action: PolicyAction) -> DecisionSeverity? {
    switch action {
    case .queueDecision(let payload): payload.severity
    case .notifyOnly(let payload): payload.severity
    default: nil
    }
  }

  private func actionPayloadJSON(_ action: PolicyAction) -> String {
    guard
      let data = try? JSONEncoder().encode(action),
      let text = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return text
  }
}

// MARK: - Fixture

extension PolicyExecutor {
  /// Convenience factory for tests. Creates an executor backed by an in-memory `DecisionStore`
  /// and no-op fakes.
  public static func fixture() throws -> PolicyExecutor {
    PolicyExecutor(
      api: NoOpSupervisorAPIClient(),
      decisions: try DecisionStore.makeInMemory(),
      audit: NoOpSupervisorAuditWriter()
    )
  }
}

// MARK: - No-op implementations (used by fixture)

private struct NoOpSupervisorAPIClient: SupervisorAPIClient {
  func nudgeAgent(agentID: String, input: String) async throws {}
  func assignTask(taskID: String, agentID: String) async throws {}
  func dropTask(taskID: String, reason: String) async throws {}
  func postNotification(
    ruleID: String,
    severity: DecisionSeverity,
    summary: String,
    decisionID: String?
  ) async {
    _ = (ruleID, severity, summary, decisionID)
  }
}

extension PolicyAction {
  fileprivate var auditTickID: String {
    switch self {
    case .nudgeAgent(let payload):
      payload.snapshotID
    case .assignTask(let payload):
      payload.snapshotID
    case .dropTask(let payload):
      payload.snapshotID
    case .queueDecision(let payload):
      payload.id
    case .notifyOnly(let payload):
      payload.snapshotID
    case .logEvent(let payload):
      payload.snapshotID
    case .suggestConfigChange(let payload):
      payload.id
    }
  }
}

func redactSupervisorErrorMessage(_ message: String) -> String {
  guard !message.isEmpty else {
    return message
  }

  let pattern = #"(?i)\b(token|secret|password|authorization|api[_-]?key)=([^\s,;]+)"#
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return message
  }
  let range = NSRange(message.startIndex..<message.endIndex, in: message)
  return regex.stringByReplacingMatches(
    in: message,
    options: [],
    range: range,
    withTemplate: "$1=[redacted]"
  )
}
