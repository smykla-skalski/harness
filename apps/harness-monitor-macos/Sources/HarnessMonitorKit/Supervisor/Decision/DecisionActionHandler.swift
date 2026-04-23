import Foundation

/// Handler the `DecisionDetailView` uses to route user interactions. Production implementations
/// bridge into `DecisionStore` + live transport; tests supply recording fakes.
@MainActor
public protocol DecisionActionHandler: AnyObject {
  func resolve(decisionID: String, outcome: DecisionOutcome) async
  func snooze(decisionID: String, duration: TimeInterval) async
  func dismiss(decisionID: String) async
}

/// No-op handler used by previews and Phase 1 callers that have no live store wired up.
@MainActor
public final class NullDecisionActionHandler: DecisionActionHandler {
  public init() {}

  public func resolve(decisionID: String, outcome: DecisionOutcome) async {
    _ = (decisionID, outcome)
  }

  public func snooze(decisionID: String, duration: TimeInterval) async {
    _ = (decisionID, duration)
  }

  public func dismiss(decisionID: String) async {
    _ = decisionID
  }
}
