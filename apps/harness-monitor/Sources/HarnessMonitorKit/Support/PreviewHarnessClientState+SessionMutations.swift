import Foundation

extension PreviewHarnessClientState {
  func dropTask(
    sessionID: String,
    taskID: String,
    request: TaskDropRequest
  ) throws -> SessionDetail {
    guard let detail = detail(for: sessionID, scope: nil) else {
      throw HarnessMonitorAPIError.server(
        code: 404,
        message: "No preview session detail available"
      )
    }

    guard let taskIndex = detail.tasks.firstIndex(where: { $0.taskId == taskID }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "No preview task available")
    }

    let targetAgentID: String
    switch request.target {
    case .agent(let agentID):
      targetAgentID = agentID
    }

    guard let agentIndex = detail.agents.firstIndex(where: { $0.agentId == targetAgentID }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "No preview agent available")
    }

    let agent = detail.agents[agentIndex]
    guard agent.role == .worker, agent.status == .active else {
      throw HarnessMonitorAPIError.server(code: 409, message: "Preview agent cannot take tasks")
    }

    var tasks = detail.tasks
    let agents = detail.agents
    let task = tasks[taskIndex]
    tasks[taskIndex] = task.replacingAssignment(
      status: .open,
      assignedTo: targetAgentID,
      queuePolicy: request.queuePolicy,
      queuedAt: agent.currentTaskId == nil ? nil : Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )

    let updatedDetail = SessionDetail(
      session: detail.session.replacing(tasks: tasks, agents: agents),
      agents: agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )

    detailsBySessionID[sessionID] = updatedDetail
    if coreDetailsBySessionID[sessionID] != nil {
      coreDetailsBySessionID[sessionID] = updatedDetail
    }
    if let sessionIndex = sessionSummaries.firstIndex(where: { $0.sessionId == sessionID }) {
      sessionSummaries[sessionIndex] = updatedDetail.session
    }
    return updatedDetail
  }

  func removeAgent(
    sessionID: String,
    agentID: String
  ) throws -> SessionDetail {
    guard let detail = detail(for: sessionID, scope: nil) else {
      throw HarnessMonitorAPIError.server(
        code: 404,
        message: "No preview session detail available"
      )
    }

    guard let agentIndex = detail.agents.firstIndex(where: { $0.agentId == agentID }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "No preview agent available")
    }

    let removedAgent = detail.agents[agentIndex]
    guard removedAgent.role != .leader else {
      throw HarnessMonitorAPIError.server(code: 409, message: "Preview leader cannot be removed")
    }

    var agents = detail.agents
    agents.remove(at: agentIndex)

    let tasks = detail.tasks.map { task in
      guard task.assignedTo == agentID else {
        return task
      }

      return task.replacingAssignment(
        status: .open,
        assignedTo: nil,
        queuePolicy: task.queuePolicy,
        queuedAt: nil,
        updatedAt: Self.mutationTimestamp
      )
    }

    let managedAgentID = removedAgent.managedAgentID
    agentTuisBySessionID[sessionID]?.removeAll { snapshot in
      snapshot.sessionAgentID == agentID || snapshot.managedAgentID == managedAgentID
    }
    acpAgentsBySessionID[sessionID]?.removeAll { snapshot in
      snapshot.sessionAgentID == agentID || snapshot.managedAgentID == managedAgentID
    }

    let updatedDetail = SessionDetail(
      session: detail.session.replacing(tasks: tasks, agents: agents),
      agents: agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )

    storeMutatedSessionDetail(updatedDetail)
    return updatedDetail
  }
}
