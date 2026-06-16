import Foundation

/// Observer protocol invoked by the Monitor supervisor loop. Phase 1 signature freeze: workers
/// may add new default implementations but cannot change the required member surface.
///
/// The AI-agent extension seam documented in source plan Task 19 lives here: an external
/// `AIPolicyObserver` can conform to this protocol and plug into the registry via
/// `PolicyRegistry.registerObserver(_:)`.
public protocol PolicyObserver: Sendable {
  func willTick(_ snapshot: SessionsSnapshot) async
  func didEvaluate(rule: any PolicyRule, actions: [SupervisorAction]) async
  func didExecute(action: SupervisorAction, outcome: PolicyOutcome) async
  func proposeConfigSuggestion(
    history: PolicyHistoryWindow
  ) async -> [SupervisorAction.ConfigSuggestion]
}

extension PolicyObserver {
  public func willTick(_ snapshot: SessionsSnapshot) async {}
  public func didEvaluate(rule: any PolicyRule, actions: [SupervisorAction]) async {}
  public func didExecute(action: SupervisorAction, outcome: PolicyOutcome) async {}
  public func proposeConfigSuggestion(
    history: PolicyHistoryWindow
  ) async -> [SupervisorAction.ConfigSuggestion] { [] }
}
