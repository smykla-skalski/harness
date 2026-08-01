import Foundation

extension TaskBoardItem {
  func withOptimisticPosition(
    status: TaskBoardStatus,
    lanePosition: UInt32,
    actor: String
  ) -> TaskBoardItem {
    withTaskBoardPosition(
      status: status,
      lanePosition: lanePosition,
      laneOrigin: .manual(actor: actor),
      laneSetAt: laneSetAt
    )
  }

  fileprivate func hasSameTaskBoardPosition(as other: TaskBoardItem) -> Bool {
    status == other.status
      && lanePosition == other.lanePosition
      && laneOrigin == other.laneOrigin
      && laneSetAt == other.laneSetAt
  }

  fileprivate func withTaskBoardPosition(
    status: TaskBoardStatus,
    lanePosition: UInt32?,
    laneOrigin: TaskBoardLaneOrigin?,
    laneSetAt: String?
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: schemaVersion,
      id: id,
      title: title,
      body: body,
      status: status,
      priority: priority,
      tags: tags,
      projectId: projectId,
      sourceProjectId: sourceProjectId,
      executionRepository: executionRepository,
      targetProjectTypes: targetProjectTypes,
      agentMode: agentMode,
      kind: kind,
      externalRefs: externalRefs,
      importedFromProvider: importedFromProvider,
      planning: planning,
      workflow: workflow,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: usage,
      parentItemId: parentItemId,
      childOrder: childOrder,
      lanePosition: lanePosition,
      laneOrigin: laneOrigin,
      laneSetAt: laneSetAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt
    )
  }
}
