import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func replacing(tasks: [WorkItem]) -> SessionDetail {
    SessionDetail(
      session: updatedSession(),
      agents: detail.agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )
  }

  func replacingTask(
    _ taskID: String,
    transform: (WorkItem) -> WorkItem
  ) -> SessionDetail {
    let tasks = detail.tasks.map { task in
      task.taskId == taskID ? transform(task) : task
    }
    return SessionDetail(
      session: updatedSession(),
      agents: detail.agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )
  }

  func replacingAgent(
    _ agentID: String,
    transform: (AgentRegistration) -> AgentRegistration
  ) -> SessionDetail {
    let agents = detail.agents.map { agent in
      agent.agentId == agentID ? transform(agent) : agent
    }
    let updatedAgent = agents.first { $0.agentId == agentID }
    return SessionDetail(
      session: updatedSession(),
      agents: agents,
      tasks: detail.tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity.map { activity in
        activity.agentId == agentID
          ? AgentToolActivitySummary(
            agentId: updatedAgent?.agentId ?? activity.agentId,
            runtime: updatedAgent?.runtime ?? activity.runtime,
            toolInvocationCount: activity.toolInvocationCount,
            toolResultCount: activity.toolResultCount,
            toolErrorCount: activity.toolErrorCount,
            latestToolName: activity.latestToolName,
            latestEventAt: activity.latestEventAt,
            recentTools: activity.recentTools
          )
          : activity
      }
    )
  }

  func updatedSession() -> SessionSummary {
    SessionSummary(
      projectId: detail.session.projectId,
      projectName: detail.session.projectName,
      projectDir: detail.session.projectDir,
      contextRoot: detail.session.contextRoot,
      sessionId: detail.session.sessionId,
      title: detail.session.title,
      context: detail.session.context,
      status: detail.session.status,
      createdAt: detail.session.createdAt,
      updatedAt: "2026-03-28T14:24:00Z",
      lastActivityAt: "2026-03-28T14:24:00Z",
      leaderId: detail.session.leaderId,
      observeId: detail.session.observeId,
      pendingLeaderTransfer: detail.session.pendingLeaderTransfer,
      metrics: detail.session.metrics
    )
  }

  func note(from request: TaskUpdateRequest) -> [TaskNote] {
    guard let note = request.note else {
      return []
    }
    return [
      TaskNote(
        timestamp: "2026-03-28T14:21:00Z",
        agentId: request.actor,
        text: note
      )
    ]
  }
}
