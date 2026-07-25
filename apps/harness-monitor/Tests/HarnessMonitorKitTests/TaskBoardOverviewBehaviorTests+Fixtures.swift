import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension TaskBoardOverviewBehaviorTests {
  func inboxItem(
    taskID: String,
    status: TaskStatus = .inProgress,
    title: String = "Linked task"
  ) -> TaskBoardInboxItem {
    let item = TaskBoardInboxItem(
      session: PreviewFixtures.summary,
      task: WorkItem(
        taskId: taskID,
        title: title,
        context: nil,
        severity: .medium,
        status: status,
        assignedTo: nil,
        createdAt: "2026-05-14T10:00:00Z",
        updatedAt: "2026-05-14T10:01:00Z",
        createdBy: nil,
        notes: [],
        suggestedFix: nil,
        source: .manual,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: nil
      )
    )
    guard let item else {
      preconditionFailure("expected task board inbox item fixture")
    }
    return item
  }

  func taskBoardItem(
    id: String,
    status: TaskBoardStatus,
    priority: TaskBoardPriority = .medium,
    targetProjectTypes: [String] = [],
    projectId: String? = "project-1",
    kind: TaskBoardItemKind = .task,
    externalRefs: [TaskBoardExternalRef] = [],
    planning: TaskBoardPlanningState = TaskBoardPlanningState(),
    sessionId: String? = nil,
    workItemId: String? = nil,
    deletedAt: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item",
      body: "Body",
      status: status,
      priority: priority,
      tags: [],
      projectId: projectId,
      targetProjectTypes: targetProjectTypes,
      agentMode: .interactive,
      kind: kind,
      externalRefs: externalRefs,
      planning: planning,
      workflow: nil,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: deletedAt
    )
  }

  func decision(
    id: String,
    severity: DecisionSeverity,
    statusRaw: String = "open"
  ) -> Decision {
    let decision = Decision(
      id: id,
      severity: severity,
      ruleID: "rule-\(id)",
      sessionID: PreviewFixtures.summary.sessionId,
      agentID: nil,
      taskID: nil,
      summary: id,
      contextJSON: "{}",
      suggestedActionsJSON: "[]",
      createdAt: Date(timeIntervalSinceReferenceDate: 801_000_000)
    )
    decision.statusRaw = statusRaw
    return decision
  }
}
