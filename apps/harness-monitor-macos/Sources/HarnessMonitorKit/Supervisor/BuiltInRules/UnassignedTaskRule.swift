import Foundation

/// Unassigned-task rule. Phase 2 worker 8 implements the body per source plan Task 12: trigger
/// when the session has tasks in `open` while ≥ 1 agent is `active`; cautious default queues a
/// decision with suggested "Assign to {agentID}" actions.
public struct UnassignedTaskRule: PolicyRule {
  public let id = "unassigned-task"
  public let name = "Unassigned Task"
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
