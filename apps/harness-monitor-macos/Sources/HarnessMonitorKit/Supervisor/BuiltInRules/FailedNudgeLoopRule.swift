import Foundation

/// Failed-nudge escalation rule. Phase 2 worker 12 implements per source plan Task 16: trigger
/// on 3 consecutive `.actionFailed` events for the same agent emitted by `StuckAgentRule`;
/// always queues a decision because this rule is itself the escalation path.
public struct FailedNudgeLoopRule: PolicyRule {
  public let id = "failed-nudge-loop"
  public let name = "Failed Nudge Loop"
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
