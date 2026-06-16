import Foundation

struct DeferredSupervisorNotificationError: LocalizedError {
  let underlying: Error

  var errorDescription: String? {
    underlying.localizedDescription
  }
}

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

private struct NoOpSupervisorAPIClient: SupervisorAPIClient {
  func nudgeAgent(agentID: String, input: String) async throws {}
  func assignTask(sessionID: String?, taskID: String, agentID: String) async throws {}
  func dropTask(sessionID: String?, taskID: String, reason: String) async throws {}
  func postNotification(
    ruleID: String,
    severity: DecisionSeverity,
    summary: String,
    decisionID: String?
  ) async throws {
    _ = (ruleID, severity, summary, decisionID)
  }
}

extension SupervisorAction {
  var auditTickID: String {
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

  let alternatives = SupervisorAuditSensitiveKeys.names
    .map(escapeForRegexAlternation)
    .sorted()
    .joined(separator: "|")
  let pattern = "(?i)\\b(\(alternatives))=([^\\s,;]+)"
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return message
  }
  let range = NSRange(message.startIndex..<message.endIndex, in: message)
  return regex.stringByReplacingMatches(
    in: message,
    options: [],
    range: range,
    withTemplate: "$1=\(SupervisorAuditSensitiveKeys.redactionPlaceholder)"
  )
}

private func escapeForRegexAlternation(_ value: String) -> String {
  NSRegularExpression.escapedPattern(for: value)
}
