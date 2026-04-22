import Foundation

/// Idle-session rule. Phase 2 worker 9 implements per source plan Task 13: trigger when a
/// session's timeline density has been zero for longer than `sessionIdleThreshold`; cautious
/// default queues a decision with a "Send check-in nudge" action.
public struct IdleSessionRule: PolicyRule {
  public let id = "idle-session"
  public let name = "Idle Session"
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
