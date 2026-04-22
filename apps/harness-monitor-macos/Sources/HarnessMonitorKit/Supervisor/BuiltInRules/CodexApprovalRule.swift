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
    _ = (snapshot, context)
    return []
  }
}
