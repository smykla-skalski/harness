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
    summary: String
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
  public func execute(_ action: PolicyAction) async -> PolicyOutcome {
    let key = action.actionKey
    pruneExpiredKeys()

    if recentKeys[key] != nil {
      return .skippedDuplicate(actionKey: key)
    }

    let dispatchRecord = auditRecord(
      id: UUID().uuidString,
      kind: "actionDispatched",
      action: action
    )
    await audit.append(dispatchRecord)
    recentKeys[key] = Date()

    do {
      try await dispatch(action)
      let executedRecord = auditRecord(
        id: UUID().uuidString,
        kind: "actionExecuted",
        action: action
      )
      await audit.append(executedRecord)
      return .executed(actionKey: key)
    } catch {
      HarnessMonitorLogger.supervisor.warning(
        "action failed key=\(key, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      let failedRecord = auditRecord(
        id: UUID().uuidString,
        kind: "actionFailed",
        action: action
      )
      await audit.append(failedRecord)
      return .failed(actionKey: key, error: error.localizedDescription)
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
    action: PolicyAction
  ) -> SupervisorAuditRecord {
    SupervisorAuditRecord(
      id: id,
      tickID: "executor",
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
      try await decisions.insert(draft)

    case .notifyOnly(let payload):
      await api.postNotification(
        ruleID: payload.ruleID,
        severity: payload.severity,
        summary: payload.summary
      )

    case .logEvent(let payload):
      HarnessMonitorLogger.supervisor.info("logEvent: \(payload.message, privacy: .public)")

    case .suggestConfigChange(let payload):
      HarnessMonitorLogger.supervisor.info(
        "suggestConfigChange ruleID=\(payload.ruleID, privacy: .public) rationale=\(payload.rationale, privacy: .public)"
      )
    }
  }

  private func ruleID(for action: PolicyAction) -> String? {
    switch action {
    case .nudgeAgent(let p): p.ruleID
    case .assignTask(let p): p.ruleID
    case .dropTask(let p): p.ruleID
    case .queueDecision(let p): p.ruleID
    case .notifyOnly(let p): p.ruleID
    case .logEvent(let p): p.ruleID
    case .suggestConfigChange(let p): p.ruleID
    }
  }

  private func severity(for action: PolicyAction) -> DecisionSeverity? {
    switch action {
    case .queueDecision(let p): p.severity
    case .notifyOnly(let p): p.severity
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
  func postNotification(ruleID: String, severity: DecisionSeverity, summary: String) async {}
}

private struct NoOpSupervisorAuditWriter: SupervisorAuditWriter {
  func append(_ record: SupervisorAuditRecord) async {}
}
