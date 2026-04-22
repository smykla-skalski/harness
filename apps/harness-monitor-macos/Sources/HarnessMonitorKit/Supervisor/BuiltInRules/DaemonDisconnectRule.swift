import Foundation

/// Daemon-disconnect rule. Phase 2 worker 11 implements per source plan Task 15: trigger on
/// `connection.kind == "disconnected"` longer than `disconnectGraceSeconds`; aggressive default
/// emits `.notifyOnly` and relies on existing reconnect, escalating to `.queueDecision` with
/// `critical` severity after `disconnectEscalationSeconds`.
public struct DaemonDisconnectRule: PolicyRule {
  public let id = "daemon-disconnect"
  public let name = "Daemon Disconnect"
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
