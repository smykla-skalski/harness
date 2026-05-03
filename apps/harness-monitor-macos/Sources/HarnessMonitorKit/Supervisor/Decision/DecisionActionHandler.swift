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

  private static func executeSuggestedActionBeforeResolve(
    _ action: SuggestedAction,
    for decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws {
    switch action.kind {
    case .nudge:
      try await executeNudgeAction(action, decision: decision, store: store)
    case .assignTask:
      try await executeAssignTaskAction(action, decision: decision, store: store)
    case .dropTask:
      try await executeDropTaskAction(action, decision: decision, store: store)
    case .custom:
      try await handleCustomAction(action, for: decision, store: store)
    case .dismiss, .snooze:
      return
    }
  }

  private static func executeNudgeAction(
    _ action: SuggestedAction,
    decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws {
    guard let agentID = resolveAgentID(from: action, decision: decision) else {
      throw StoreDecisionActionError.missingTargetMetadata("agentID")
    }
    guard let client = await MainActor.run(body: { store.client }) else {
      throw StoreDecisionActionError.daemonUnavailable
    }
    let input = resolveNudgeInput(from: action)
    do {
      _ = try await client.sendManagedAgentInput(
        agentID: agentID,
        request: AgentTuiInputRequest(input: .text(input))
      )
    } catch {
      throw StoreDecisionActionError.daemonRejected(error)
    }
  }

  private static func executeAssignTaskAction(
    _ action: SuggestedAction,
    decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws {
    let payload = try decodeTaskActionPayload(action.payloadJSON)
    guard let client = await MainActor.run(body: { store.client }) else {
      throw StoreDecisionActionError.daemonUnavailable
    }
    guard
      let sessionID = try await resolveSessionIDForTask(
        payload.taskID,
        decision: decision,
        store: store
      )
    else {
      throw StoreDecisionActionError.missingTargetMetadata("sessionID")
    }
    do {
      _ = try await client.assignTask(
        sessionID: sessionID,
        taskID: payload.taskID,
        request: TaskAssignRequest(actor: "harness-supervisor", agentId: payload.agentID)
      )
    } catch {
      throw StoreDecisionActionError.daemonRejected(error)
    }
  }

  private static func executeDropTaskAction(
    _ action: SuggestedAction,
    decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws {
    let payload = try decodeTaskActionPayload(action.payloadJSON)
    guard let client = await MainActor.run(body: { store.client }) else {
      throw StoreDecisionActionError.daemonUnavailable
    }
    guard
      let location = try await resolveTaskLocation(
        payload.taskID,
        decision: decision,
        store: store
      )
    else {
      throw StoreDecisionActionError.missingTargetMetadata("sessionID")
    }
    guard let assignedAgentID = location.assignedAgentID else {
      throw StoreDecisionActionError.missingTargetMetadata("assignedAgentID")
    }
    do {
      _ = try await client.dropTask(
        sessionID: location.sessionID,
        taskID: payload.taskID,
        request: TaskDropRequest(
          actor: "harness-supervisor",
          target: .agent(agentId: assignedAgentID),
          queuePolicy: .locked
        )
      )
    } catch {
      throw StoreDecisionActionError.daemonRejected(error)
    }
  }

  private static func handleCustomAction(
    _ action: SuggestedAction,
    for decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws {
    switch decision.ruleID {
    case "codex-approval":
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
    default:
      try await handleSupervisorCustomAction(action, store: store)
    }
  }

  private static func resolveAgentID(
    from action: SuggestedAction,
    decision: DecisionActionSnapshot
  ) -> String? {
    if let payload = try? JSONDecoder().decode(
      NudgeActionPayload.self,
      from: Data(action.payloadJSON.utf8)
    ),
      let agentID = payload.agentID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !agentID.isEmpty
    {
      return agentID
    }
    if let context = DecisionContextEnvelope(decision.contextJSON),
      let agentID = context.agentID
    {
      return agentID
    }
    return decision.agentID
  }

  private static func resolveNudgeInput(from action: SuggestedAction) -> String {
    if let payload = try? JSONDecoder().decode(
      NudgeActionPayload.self,
      from: Data(action.payloadJSON.utf8)
    ),
      let message = payload.input?.trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty
    {
      return message
    }
    return "Quick check-in from Harness Monitor supervisor."
  }

  private static func decodeTaskActionPayload(_ json: String) throws -> TaskActionPayload {
    guard
      let payload = try? JSONDecoder().decode(
        TaskActionPayload.self,
        from: Data(json.utf8)
      ),
      !payload.taskID.isEmpty,
      !payload.agentID.isEmpty
    else {
      throw StoreDecisionActionError.missingTargetMetadata("task action payload")
    }
    return payload
  }

  private static func resolveSessionIDForTask(
    _ taskID: String,
    decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws -> String? {
    if let location = try await resolveTaskLocation(taskID, decision: decision, store: store) {
      return location.sessionID
    }
    return decision.sessionID
  }

  private static func resolveTaskLocation(
    _ taskID: String,
    decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws -> TaskLocation? {
    if let selectedSession = await MainActor.run(body: { store.selectedSession }),
      let task = selectedSession.tasks.first(where: { $0.taskId == taskID })
    {
      return TaskLocation(
        sessionID: selectedSession.session.sessionId,
        assignedAgentID: task.assignedTo
      )
    }

    let sessionIDHint = decision.sessionID
    let (sessionIDs, cacheService) = await MainActor.run {
      (store.sessionIndex.sessions.map(\.sessionId), store.cacheService)
    }
    guard let cacheService else {
      return nil
    }

    let prioritizedSessionIDs = prioritizeSessionIDs(sessionIDs, hint: sessionIDHint)
    let cachedSessions = await cacheService.loadSessionDetails(sessionIDs: prioritizedSessionIDs)
    for sessionID in prioritizedSessionIDs {
      guard let detail = cachedSessions[sessionID]?.detail else {
        continue
      }
      guard let task = detail.tasks.first(where: { $0.taskId == taskID }) else {
        continue
      }
      return TaskLocation(sessionID: sessionID, assignedAgentID: task.assignedTo)
    }
    return nil
  }

  private static func prioritizeSessionIDs(_ sessionIDs: [String], hint: String?) -> [String] {
    guard let hint, sessionIDs.contains(hint) else {
      return sessionIDs
    }
    return [hint] + sessionIDs.filter { $0 != hint }
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
