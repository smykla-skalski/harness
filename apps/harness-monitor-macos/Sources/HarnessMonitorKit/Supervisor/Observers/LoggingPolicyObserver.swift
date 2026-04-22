import Foundation

import OSLog

/// Built-in observer that mirrors every tick, rule evaluation, and action outcome into
/// `HarnessMonitorLogger.supervisor`. Phase 1 ships the symbol so the registry can reference
/// it; Phase 2 worker 15 fills in structured logging and documents the AI-observer extension
/// point.
public final class LoggingPolicyObserver: PolicyObserver {
  public init() {}

  public func willTick(_ snapshot: SessionsSnapshot) async {
    _ = snapshot
  }

  public func didEvaluate(rule: any PolicyRule, actions: [PolicyAction]) async {
    _ = (rule, actions)
  }

  public func didExecute(action: PolicyAction, outcome: PolicyOutcome) async {
    _ = (action, outcome)
  }
}
