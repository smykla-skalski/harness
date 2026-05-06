import Foundation

/// Handler the `DecisionDetailView` uses to route user interactions. Production implementations
/// bridge into `DecisionStore` + live transport; tests supply recording fakes.
@MainActor
public protocol DecisionActionHandler: AnyObject {
  func resolve(decisionID: String, outcome: DecisionOutcome) async
  func snooze(decisionID: String, duration: TimeInterval) async
  func dismiss(decisionID: String) async
  func cancelSignal(signalID: String, agentID: String) async
  func resendSignal(_ record: SessionSignalRecord) async
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

  public func cancelSignal(signalID: String, agentID: String) async {}
  public func resendSignal(_ record: SessionSignalRecord) async {}
}

@MainActor
public final class StoreDecisionActionHandler: DecisionActionHandler {
  let store: HarnessMonitorStore
  private let decisions: DecisionStore

  public init(store: HarnessMonitorStore, decisions: DecisionStore) {
    self.store = store
    self.decisions = decisions
  }

  public func resolve(decisionID: String, outcome: DecisionOutcome) async {
    do {
      guard let decision = try await decisions.decision(id: decisionID) else {
        throw StoreDecisionActionError.missingDecision(decisionID)
      }
      let decisionSnapshot = DecisionActionSnapshot(decision: decision)
      if decisionSnapshot.ruleID == AcpPermissionDecisionPayload.ruleID,
        let actionID = outcome.chosenActionID
      {
        _ = await store.submitAcpPermissionDecisionAction(
          decisionID: decisionID,
          actionID: actionID,
          decisionStore: self.decisions
        )
        return
      }
      let action = Self.suggestedAction(
        in: decisionSnapshot.suggestedActionsJSON,
        matching: outcome.chosenActionID
      )

      try await store.withSupervisorAutoActionsSuppressed {
        if let action {
          try await Self.executeSuggestedActionBeforeResolve(
            action,
            for: decisionSnapshot,
            store: self.store
          )
        }
        if outcome.chosenActionID == HarnessMonitorNotificationActionID.acknowledge {
          try await Self.handleNotificationAcknowledgement(
            for: decisionSnapshot,
            decisions: self.decisions
          )
          return
        }
        try await self.decisions.resolve(id: decisionID, outcome: outcome)
      }
    } catch {
      store.presentFailureFeedback(redactSupervisorErrorMessage(error.localizedDescription))
    }
  }

  public func snooze(decisionID: String, duration: TimeInterval) async {
    do {
      let until = Date().addingTimeInterval(duration)
      try await decisions.snooze(id: decisionID, until: until)
    } catch {
      store.presentFailureFeedback(redactSupervisorErrorMessage(error.localizedDescription))
    }
  }

  public func dismiss(decisionID: String) async {
    do {
      try await decisions.dismiss(id: decisionID)
    } catch {
      store.presentFailureFeedback(redactSupervisorErrorMessage(error.localizedDescription))
    }
  }

  private static func handleNotificationAcknowledgement(
    for decision: DecisionActionSnapshot,
    decisions: DecisionStore
  ) async throws {
    if decision.ruleID == "codex-approval" {
      try await decisions.snooze(id: decision.id, until: Date().addingTimeInterval(60 * 60))
      return
    }
    try await decisions.dismiss(id: decision.id)
  }

  private static func suggestedAction(
    in suggestedActionsJSON: String,
    matching actionID: String?
  ) -> SuggestedAction? {
    guard
      let actionID,
      let data = suggestedActionsJSON.data(using: .utf8),
      let actions = try? JSONDecoder().decode([SuggestedAction].self, from: data)
    else {
      return nil
    }
    return actions.first(where: { $0.id == actionID })
  }

}
