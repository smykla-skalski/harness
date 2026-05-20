import Foundation

extension PreviewHarnessClientState {
  func deleteTask(sessionID: String, taskID: String) throws -> SessionDetail {
    guard let detail = detail(for: sessionID, scope: nil) else {
      throw HarnessMonitorAPIError.server(
        code: 404,
        message: "No preview session detail available"
      )
    }

    guard detail.tasks.contains(where: { $0.taskId == taskID }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "No preview task available")
    }

    let tasks = detail.tasks.filter { $0.taskId != taskID }
    let updatedDetail = SessionDetail(
      session: detail.session.replacing(tasks: tasks, agents: detail.agents),
      agents: detail.agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )
    storeMutatedSessionDetail(updatedDetail)
    return updatedDetail
  }
}
