import Foundation

@MainActor
extension StoreDecisionActionHandler {
  static func executeSuggestedActionBeforeResolve(
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

  static func executeNudgeAction(
    _ action: SuggestedAction,
    decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws {
    guard let target = await resolveNudgeTarget(from: action, decision: decision, store: store)
    else {
      throw StoreDecisionActionError.missingTargetMetadata("agentID")
    }
    guard let client = await MainActor.run(body: { store.client }) else {
      throw StoreDecisionActionError.daemonUnavailable
    }
    let input = resolveNudgeInput(from: action)
    do {
      try await SupervisorManagedAgentNudgeDispatcher.dispatch(
        managedAgentID: target.managedAgentID,
        signalAgentID: target.signalAgentID,
        input: input,
        client: client
      )
    } catch {
      throw StoreDecisionActionError.daemonRejected(error)
    }
  }

  static func executeAssignTaskAction(
    _ action: SuggestedAction,
    decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws {
    let payload = try decodeTaskActionPayload(action.payloadJSON)
    guard let client = await MainActor.run(body: { store.client }) else {
      throw StoreDecisionActionError.daemonUnavailable
    }
    let sessionID: String?
    if let payloadSessionID = payload.sessionID {
      sessionID = payloadSessionID
    } else {
      sessionID = try await resolveSessionIDForTask(
        payload.taskID,
        decision: decision,
        store: store
      )
    }
    guard let sessionID else {
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

  static func executeDropTaskAction(
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
        sessionIDHint: payload.sessionID ?? decision.sessionID,
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

  static func handleCustomAction(
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

  static func resolveNudgeTarget(
    from action: SuggestedAction,
    decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async -> ManagedAgentNudgeTarget? {
    let payload = try? JSONDecoder().decode(
      NudgeActionPayload.self,
      from: Data(action.payloadJSON.utf8)
    )
    let context = DecisionContextEnvelope(decision.contextJSON)
    let sessionAgentIdentity =
      normalizedSessionAgentIdentity(payload?.agentID)
      ?? normalizedSessionAgentIdentity(context?.agentID)
      ?? normalizedSessionAgentIdentity(decision.agentID)
    let managedAgentIdentity =
      normalizedManagedAgentIdentity(payload?.managedAgentID)
      ?? normalizedManagedAgentIdentity(context?.managedAgentID)
    switch (sessionAgentIdentity, managedAgentIdentity) {
    case (.some(let sessionAgentIdentity), .some(let managedAgentIdentity)):
      if let target = await MainActor.run(body: {
        store.managedAgentNudgeTarget(
          forManagedAgentIdentity: managedAgentIdentity
        )
      }),
        target.signalAgentID == sessionAgentIdentity.rawValue
      {
        return target
      }
      if let target = await MainActor.run(body: {
        store.managedAgentNudgeTarget(
          forSessionAgentIdentity: sessionAgentIdentity
        )
      }),
        target.managedAgentID == managedAgentIdentity.rawValue
      {
        return target
      }
      return nil
    case (.some(let sessionAgentIdentity), .none):
      return await MainActor.run(body: {
        store.managedAgentNudgeTarget(forSessionAgentIdentity: sessionAgentIdentity)
      })
    case (.none, .some(let managedAgentIdentity)):
      return await MainActor.run(body: {
        store.managedAgentNudgeTarget(forManagedAgentIdentity: managedAgentIdentity)
      })
    case (.none, .none):
      return nil
    }
  }

  static func normalizedSessionAgentIdentity(_ value: String?) -> SessionAgentID? {
    guard let value = normalizedIdentityValue(value) else {
      return nil
    }
    return SessionAgentID(rawValue: value)
  }

  static func normalizedManagedAgentIdentity(_ value: String?) -> ManagedAgentID? {
    guard let value = normalizedIdentityValue(value) else {
      return nil
    }
    return ManagedAgentID(rawValue: value)
  }

  static func normalizedIdentityValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  static func resolveNudgeInput(from action: SuggestedAction) -> String {
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

  static func decodeTaskActionPayload(_ json: String) throws -> TaskActionPayload {
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

  static func resolveSessionIDForTask(
    _ taskID: String,
    decision: DecisionActionSnapshot,
    store: HarnessMonitorStore
  ) async throws -> String? {
    if let location = try await resolveTaskLocation(
      taskID,
      sessionIDHint: decision.sessionID,
      store: store
    ) {
      return location.sessionID
    }
    return decision.sessionID
  }

  static func resolveTaskLocation(
    _ taskID: String,
    sessionIDHint: String?,
    store: HarnessMonitorStore
  ) async throws -> TaskLocation? {
    if let selectedSession = await MainActor.run(body: { store.selectedSession }),
      sessionIDHint == nil || selectedSession.session.sessionId == sessionIDHint,
      let task = selectedSession.tasks.first(where: { $0.taskId == taskID })
    {
      return TaskLocation(
        sessionID: selectedSession.session.sessionId,
        assignedAgentID: task.assignedTo
      )
    }

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

  static func prioritizeSessionIDs(_ sessionIDs: [String], hint: String?) -> [String] {
    guard let hint, sessionIDs.contains(hint) else {
      return sessionIDs
    }
    return [hint] + sessionIDs.filter { $0 != hint }
  }

  static func resolveCodexRunID(
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

  static func resolveRunID(in runs: [CodexRunSnapshot], approvalID: String) -> String? {
    runs.first { run in
      run.pendingApprovals.contains { $0.approvalId == approvalID }
    }?.runId
  }
}
