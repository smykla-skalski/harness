import Foundation

/// Codex approval rule. Phase 2 worker 13 implements per source plan Task 17: trigger on
/// `session.pendingCodexApprovals` being non-empty; always queues a decision with suggested
/// actions whose `payloadJSON` encodes the `WebSocketProtocol.managedAgentResolveCodexApproval`
/// request body (accept / acceptForSession / decline / cancel).
public struct CodexApprovalRule: PolicyRule {
  public let id = "codex-approval"
  public let name = "Codex Approval"
  public let version = 1
  public let parameters = PolicyParameterSchema(fields: [])

  public init() {}

  public func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    _ = actionKey
    return .cautious
  }

  public func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    snapshot.sessions.flatMap { session in
      session.pendingCodexApprovals.compactMap { approval in
        action(for: approval, sessionID: session.id, snapshotID: snapshot.id, context: context)
      }
    }
  }

  private func action(
    for approval: CodexApprovalSnapshot,
    sessionID: String,
    snapshotID: String,
    context: PolicyContext
  ) -> PolicyAction? {
    let decisionID = "codex-approval:\(sessionID):\(approval.id)"
    let payload = PolicyAction.DecisionPayload(
      id: decisionID,
      severity: .needsUser,
      ruleID: id,
      sessionID: sessionID,
      agentID: approval.agentID,
      taskID: nil,
      summary: approval.title,
      contextJSON: encode(ContextPayload(snapshotID: snapshotID, approval: approval)),
      suggestedActionsJSON: encode(
        makeSuggestedActions(agentID: approval.agentID, approvalID: approval.id)
      )
    )
    let action = PolicyAction.queueDecision(payload)
    guard !context.recentActionKeys.contains(action.actionKey) else {
      return nil
    }
    return action
  }

  private func makeSuggestedActions(agentID: String, approvalID: String) -> [SuggestedAction] {
    ApprovalMode.allCases.map { mode in
      SuggestedAction(
        id: mode.rawValue,
        title: mode.title,
        kind: .custom,
        payloadJSON: encode(mode.payload(agentID: agentID, approvalID: approvalID))
      )
    }
  }

  private func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard
      let data = try? encoder.encode(value),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }
}

private struct ContextPayload: Encodable {
  let snapshotID: String
  let approvalID: String
  let agentID: String
  let receivedAt: Date

  init(snapshotID: String, approval: CodexApprovalSnapshot) {
    self.snapshotID = snapshotID
    approvalID = approval.id
    agentID = approval.agentID
    receivedAt = approval.receivedAt
  }
}

private enum ApprovalMode: String, CaseIterable {
  case accept
  case acceptForSession
  case decline
  case cancel

  var title: String {
    switch self {
    case .accept:
      "Accept"
    case .acceptForSession:
      "Accept for session"
    case .decline:
      "Decline"
    case .cancel:
      "Cancel"
    }
  }

  var decision: CodexApprovalDecision {
    switch self {
    case .accept:
      .accept
    case .acceptForSession:
      .acceptForSession
    case .decline:
      .decline
    case .cancel:
      .cancel
    }
  }

  func payload(agentID: String, approvalID: String) -> ActionPayload {
    ActionPayload(
      mode: rawValue,
      agentID: agentID,
      approvalID: approvalID,
      decision: decision.rawValue
    )
  }
}

private struct ActionPayload: Encodable {
  let mode: String
  let agentID: String
  let approvalID: String
  let decision: String
}
