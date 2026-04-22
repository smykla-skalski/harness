import Foundation

/// Policy-gap teaching rule. Phase 2 worker 14 implements per source plan Task 18: trigger on
/// observer issues with `code` not present in the Swift-side `KnownClassifierCodes` constant;
/// aggressive default logs the event, cautious path queues an informational decision so the
/// user can teach a new pattern. Phase 2 also seeds the `KnownClassifierCodes` constant.
public struct PolicyGapRule: PolicyRule {
  public let id = "policy-gap"
  public let name = "Policy Gap"
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
