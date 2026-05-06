import Foundation

struct StoreAPIClient: SupervisorAPIClient {
  private struct TaskLocation {
    let sessionID: String
    let assignedAgentID: String?
  }

  private let store: HarnessMonitorStore

  init(store: HarnessMonitorStore) {
    self.store = store
  }

  func nudgeAgent(agentID: String, input: String) async throws {
    guard let client = await MainActor.run(body: { store.client }) else {
      throw StoreDecisionActionError.daemonUnavailable
    }
    guard let target = await MainActor.run(body: {
      store.managedAgentNudgeTarget(
        forSessionAgentIdentity: SessionAgentID(rawValue: agentID)
      )
    }) else {
      throw StoreDecisionActionError.missingTargetMetadata("sessionAgentID")
    }
    try await SupervisorManagedAgentNudgeDispatcher.dispatch(
      managedAgentID: target.managedAgentID,
      signalAgentID: target.signalAgentID,
      input: input,
      client: client
    )
  }

  func assignTask(sessionID: String?, taskID: String, agentID: String) async throws {
    guard let client = await MainActor.run(body: { store.client }) else {
      throw StoreDecisionActionError.daemonUnavailable
    }
    guard let location = await resolveTaskLocation(taskID: taskID, sessionID: sessionID) else {
      throw StoreDecisionActionError.missingTargetMetadata("taskID")
    }
    _ = try await client.assignTask(
      sessionID: location.sessionID,
      taskID: taskID,
      request: TaskAssignRequest(actor: "harness-supervisor", agentId: agentID)
    )
  }

  func dropTask(sessionID: String?, taskID: String, reason: String) async throws {
    guard let client = await MainActor.run(body: { store.client }) else {
      throw StoreDecisionActionError.daemonUnavailable
    }
    guard let location = await resolveTaskLocation(taskID: taskID, sessionID: sessionID) else {
      throw StoreDecisionActionError.missingTargetMetadata("taskID")
    }
    guard let assignedAgentID = location.assignedAgentID else {
      _ = reason
      throw StoreDecisionActionError.missingTargetMetadata("assignedAgentID")
    }
    _ = try await client.dropTask(
      sessionID: location.sessionID,
      taskID: taskID,
      request: TaskDropRequest(
        actor: "harness-supervisor",
        target: .agent(agentId: assignedAgentID),
        queuePolicy: .locked,
        reason: reason
      )
    )
  }

  func postNotification(
    ruleID: String,
    severity: DecisionSeverity,
    summary: String,
    decisionID: String?
  ) async throws {
    guard
      let controller = await MainActor.run(
        body: { store.supervisorBindings.notificationController }
      )
    else {
      throw StoreDecisionActionError.notificationUnavailable
    }
    let delivered =
      if let decisionID {
        await controller.deliverSupervisorDecision(
          severity: severity,
          summary: summary,
          decisionID: decisionID
        )
      } else {
        await controller.deliverSupervisorNotice(
          severity: severity,
          summary: summary,
          ruleID: ruleID
        )
      }
    guard delivered else {
      throw StoreDecisionActionError.notificationDeliveryFailed
    }
  }

  private func resolveTaskLocation(taskID: String, sessionID: String?) async -> TaskLocation? {
    if let selectedSession = await MainActor.run(body: { store.selectedSession }),
      sessionID == nil || selectedSession.session.sessionId == sessionID,
      let task = selectedSession.tasks.first(where: { $0.taskId == taskID })
    {
      return TaskLocation(
        sessionID: selectedSession.session.sessionId,
        assignedAgentID: task.assignedTo
      )
    }

    let (indexedSessionIDs, cacheService) = await MainActor.run {
      (store.sessionIndex.sessions.map(\.sessionId), store.cacheService)
    }
    guard let cacheService else {
      return nil
    }

    let sessionIDs = sessionID.map { [$0] } ?? indexedSessionIDs
    let cachedSessions = await cacheService.loadSessionDetails(sessionIDs: sessionIDs)
    for sessionID in sessionIDs {
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
}

extension HarnessMonitorStore {
  func managedAgentNudgeTarget(
    forSessionAgentIdentity sessionAgentIdentity: SessionAgentID
  ) -> ManagedAgentNudgeTarget? {
    if let linkage = acpIdentityCrosswalk().agentLinkage(
      forSessionAgentIdentity: sessionAgentIdentity
    ),
      let sessionAgentIdentity = linkage.sessionAgentIdentity
    {
      return ManagedAgentNudgeTarget(
        managedAgentID: linkage.managedAgentIdentity.rawValue,
        signalAgentID: sessionAgentIdentity.rawValue
      )
    }
    if let snapshot = selectedAgentTuis.first(where: {
      $0.sessionAgentIdentity == sessionAgentIdentity
    }) {
      return ManagedAgentNudgeTarget(
        managedAgentID: snapshot.managedAgentID,
        signalAgentID: snapshot.sessionAgentID
      )
    }
    // Legacy terminal nudge decisions can still carry the managed TUI id in `agentID`.
    let legacyManagedAgentIdentity = ManagedAgentID(rawValue: sessionAgentIdentity.rawValue)
    if let snapshot = selectedAgentTuis.first(where: {
      $0.managedAgentIdentity == legacyManagedAgentIdentity
    }) {
      return ManagedAgentNudgeTarget(
        managedAgentID: snapshot.managedAgentID,
        signalAgentID: snapshot.sessionAgentID
      )
    }
    return nil
  }

  func managedAgentNudgeTarget(
    forManagedAgentIdentity managedAgentIdentity: ManagedAgentID
  ) -> ManagedAgentNudgeTarget? {
    if let linkage = acpIdentityCrosswalk().agentLinkage(
      forManagedAgentIdentity: managedAgentIdentity
    ),
      let sessionAgentIdentity = linkage.sessionAgentIdentity
    {
      return ManagedAgentNudgeTarget(
        managedAgentID: linkage.managedAgentIdentity.rawValue,
        signalAgentID: sessionAgentIdentity.rawValue
      )
    }
    if let snapshot = selectedAgentTuis.first(where: {
      $0.managedAgentIdentity == managedAgentIdentity
    }) {
      return ManagedAgentNudgeTarget(
        managedAgentID: snapshot.managedAgentID,
        signalAgentID: snapshot.sessionAgentID
      )
    }
    return nil
  }
}
