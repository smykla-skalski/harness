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

@MainActor
public final class StoreDecisionActionHandler: DecisionActionHandler {
  private let store: HarnessMonitorStore
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
      let action = Self.suggestedAction(
        in: decisionSnapshot.suggestedActionsJSON,
        matching: outcome.chosenActionID
      )

      try await store.withSupervisorAutoActionsSuppressed {
        if outcome.chosenActionID == HarnessMonitorNotificationActionID.acknowledge {
          try await Self.handleNotificationAcknowledgement(
            for: decisionSnapshot,
            decisions: self.decisions
          )
          return
        }
        if let action {
          try await Self.handleCustomAction(
            action,
            for: decisionSnapshot,
            store: self.store
          )
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

  private static func handleCustomAction(
    _ action: SuggestedAction,
    for decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws {
    guard action.kind == .custom, decision.ruleID == "codex-approval" else {
      return
    }
    let payload = try JSONDecoder().decode(
      CodexApprovalSuggestedActionPayload.self,
      from: Data(action.payloadJSON.utf8)
    )
    guard let remoteDecision = CodexApprovalDecision(rawValue: payload.decision) else {
      throw StoreDecisionActionError.invalidCodexPayload
    }
    guard let client = await MainActor.run(body: { store.client }) else {
      throw StoreDecisionActionError.missingClient
    }
    let runID = try await resolveCodexRunID(
      decision: decision,
      payload: payload,
      store: store
    )
    let updatedRun = try await client.resolveCodexApproval(
      runID: runID,
      approvalID: payload.approvalID,
      request: CodexApprovalDecisionRequest(decision: remoteDecision)
    )
    await MainActor.run {
      store.applyCodexRun(updatedRun)
    }
  }

  private static func resolveCodexRunID(
    decision: DecisionActionSnapshot,
    payload: CodexApprovalSuggestedActionPayload,
    store: HarnessMonitorStore
  ) async throws -> String {
    if let sessionID = decision.sessionID {
      let cachedRuns = await MainActor.run {
        store.codexRunsBySessionID[sessionID] ?? []
      }
      if let runID = resolveRunID(in: cachedRuns, approvalID: payload.approvalID) {
        return runID
      }
      if let client = await MainActor.run(body: { store.client }) {
        let response = try await client.codexRuns(sessionID: sessionID)
        await MainActor.run {
          store.codexRunsBySessionID[sessionID] = response.runs
        }
        if let runID = resolveRunID(in: response.runs, approvalID: payload.approvalID) {
          return runID
        }
      }
    }
    if !payload.agentID.isEmpty {
      return payload.agentID
    }
    throw StoreDecisionActionError.missingCodexRun(payload.approvalID)
  }

  private static func resolveRunID(in runs: [CodexRunSnapshot], approvalID: String) -> String? {
    runs.first { run in
      run.pendingApprovals.contains { $0.approvalId == approvalID }
    }?.runId
  }
}

private struct CodexApprovalSuggestedActionPayload: Decodable {
  let mode: String
  let agentID: String
  let approvalID: String
  let decision: String
}

private struct DecisionActionSnapshot: Sendable {
  let id: String
  let ruleID: String
  let sessionID: String?
  let suggestedActionsJSON: String

  init(decision: Decision) {
    id = decision.id
    ruleID = decision.ruleID
    sessionID = decision.sessionID
    suggestedActionsJSON = decision.suggestedActionsJSON
  }
}

private enum StoreDecisionActionError: LocalizedError {
  case missingDecision(String)
  case missingClient
  case missingCodexRun(String)
  case invalidCodexPayload

  var errorDescription: String? {
    switch self {
    case .missingDecision(let decisionID):
      "Decision \(decisionID) is no longer available."
    case .missingClient:
      "Monitor is not connected to the daemon."
    case .missingCodexRun(let approvalID):
      "Could not locate the Codex run for approval \(approvalID)."
    case .invalidCodexPayload:
      "The Codex approval action payload is invalid."
    }
  }
}
