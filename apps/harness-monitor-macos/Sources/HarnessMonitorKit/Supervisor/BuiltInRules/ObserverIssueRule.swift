import Foundation

/// Observer-issue escalation rule. Phase 2 worker 10 implements per source plan Task 14:
/// trigger on ≥ 3 observer issues with severity ≥ warn inside `issueWindow`; cautious default
/// queues a decision bundling all related issues.
public struct ObserverIssueRule: PolicyRule {
  public let id = "observer-issue-escalation"
  public let name = "Observer Issue Escalation"
  public let version = 1
  public let parameters = PolicyParameterSchema(fields: [
    .init(key: "issueWindow", label: "Issue window", kind: .duration, default: "300"),
    .init(key: "minCount", label: "Minimum issue count", kind: .integer, default: "3"),
    .init(key: "minSeverity", label: "Minimum severity", kind: .string, default: "warn"),
  ])

  public init() {}

  public func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    _ = actionKey
    return .cautious
  }

  public func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    snapshot.sessions.compactMap { session in
      action(for: session, snapshot: snapshot, context: context)
    }
  }

  private func action(
    for session: SessionSnapshot,
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) -> PolicyAction? {
    let issues = qualifyingIssues(in: session, context: context)
    guard issues.count >= minCount(in: context) else { return nil }

    let payload = PolicyAction.DecisionPayload(
      id: "observer-issue-\(session.id)-\(snapshot.hash)",
      severity: maxSeverity(in: issues),
      ruleID: id,
      sessionID: session.id,
      agentID: nil,
      taskID: nil,
      summary: "Observer reported \(issues.count) issue(s) in session \(session.id)",
      contextJSON: bundleJSON(sessionID: session.id, issues: issues),
      suggestedActionsJSON: "[]"
    )
    let action = PolicyAction.queueDecision(payload)
    guard !context.recentActionKeys.contains(action.actionKey) else { return nil }
    return action
  }

  private func qualifyingIssues(
    in session: SessionSnapshot,
    context: PolicyContext
  ) -> [ObserverIssueSnapshot] {
    let minimumSeverity = minSeverity(in: context)
    let windowStart = context.now.addingTimeInterval(-TimeInterval(issueWindow(in: context)))
    return session.observerIssues.filter { issue in
      guard let firstSeen = issue.firstSeen, firstSeen >= windowStart else { return false }
      return severity(for: issue).sortKey >= minimumSeverity.sortKey
    }
  }

  private func issueWindow(in context: PolicyContext) -> Int {
    context.parameters.seconds("issueWindow", default: 300)
  }

  private func minCount(in context: PolicyContext) -> Int {
    context.parameters.int("minCount", default: 3)
  }

  private func minSeverity(in context: PolicyContext) -> DecisionSeverity {
    DecisionSeverity(rawValue: context.parameters.string("minSeverity", default: "warn")) ?? .warn
  }

  private func maxSeverity(in issues: [ObserverIssueSnapshot]) -> DecisionSeverity {
    issues.reduce(.info) { current, issue in
      let next = severity(for: issue)
      return next.sortKey > current.sortKey ? next : current
    }
  }

  private func severity(for issue: ObserverIssueSnapshot) -> DecisionSeverity {
    DecisionSeverity(rawValue: issue.severityRaw) ?? .info
  }

  private func bundleJSON(
    sessionID: String,
    issues: [ObserverIssueSnapshot]
  ) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bundle = ObserverBundle(
      sessionID: sessionID,
      issues: issues.map(ObserverBundle.Entry.init(issue:))
    )
    guard let data = try? encoder.encode(bundle),
      let json = String(data: data, encoding: .utf8)
    else {
      return #"{"sessionID":"","issues":[]}"#
    }
    return json
  }
}

private struct ObserverBundle: Encodable {
  let sessionID: String
  let issues: [Entry]

  struct Entry: Encodable {
    let id: String
    let code: String
    let severity: String
    let firstSeen: Date
    let count: Int

    init(issue: ObserverIssueSnapshot) {
      self.id = issue.id
      self.code = issue.code
      self.severity = issue.severityRaw
      self.firstSeen = issue.firstSeen ?? .distantPast
      self.count = issue.count
    }
  }
}

extension DecisionSeverity {
  fileprivate var sortKey: Int {
    switch self {
    case .critical: 4
    case .needsUser: 3
    case .warn: 2
    case .info: 1
    }
  }
}
