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
    guard let client = await MainActor.run(body: { store.client }) else { return }
    let request = AgentTuiInputRequest(input: .text(input))
    _ = try await client.sendManagedAgentInput(agentID: agentID, request: request)
  }

  func assignTask(taskID: String, agentID: String) async throws {
    guard
      let client = await MainActor.run(body: { store.client }),
      let location = await resolveTaskLocation(taskID: taskID)
    else {
      return
    }
    _ = try await client.assignTask(
      sessionID: location.sessionID,
      taskID: taskID,
      request: TaskAssignRequest(actor: "harness-supervisor", agentId: agentID)
    )
  }

  func dropTask(taskID: String, reason: String) async throws {
    guard
      let client = await MainActor.run(body: { store.client }),
      let location = await resolveTaskLocation(taskID: taskID),
      let assignedAgentID = location.assignedAgentID
    else {
      _ = reason
      return
    }
    _ = try await client.dropTask(
      sessionID: location.sessionID,
      taskID: taskID,
      request: TaskDropRequest(
        actor: "harness-supervisor",
        target: .agent(agentId: assignedAgentID),
        queuePolicy: .locked
      )
    )
  }

  func postNotification(
    ruleID: String,
    severity: DecisionSeverity,
    summary: String,
    decisionID: String?
  ) async {
    guard let decisionID else {
      _ = ruleID
      return
    }
    await MainActor.run {
      guard let controller = store.supervisorBindings.notificationController else {
        return
      }
      Task { @MainActor in
        await controller.deliverSupervisorDecision(
          severity: severity,
          summary: summary,
          decisionID: decisionID
        )
      }
    }
  }

  private func resolveTaskLocation(taskID: String) async -> TaskLocation? {
    if let selectedSession = await MainActor.run(body: { store.selectedSession }),
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
