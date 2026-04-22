import Foundation

/// Stuck-agent detection rule. Phase 2 worker 7 implements the body per source plan Task 11:
/// trigger on `agent.idleSeconds > stuckThreshold` while the agent owns an in-progress task,
/// aggressively nudge up to N times, then queue a decision.
public struct StuckAgentRule: PolicyRule {
  public let id = "stuck-agent"
  public let name = "Stuck Agent"
  public let version = 1
  public let parameters = PolicyParameterSchema(fields: [])

  public init() {}

  public func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    _ = actionKey
    return .aggressive
  }

  public func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    _ = (snapshot, context)
    return []
  }
}
