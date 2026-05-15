import Foundation

extension PreviewHarnessClientState {
  func currentTaskBoardItems(status: TaskBoardStatus?) -> [TaskBoardItem] {
    guard let status else {
      return taskBoardItems
    }
    return taskBoardItems.filter { $0.status == status }
  }

  func updateTaskBoardItem(id: String, request: TaskBoardUpdateItemRequest) throws
    -> TaskBoardItem
  {
    guard let index = taskBoardItems.firstIndex(where: { $0.id == id }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable.")
    }
    let updated = taskBoardItems[index].applyingPreviewUpdate(request)
    taskBoardItems[index] = updated
    return updated
  }
}

extension TaskBoardItem {
  fileprivate func applyingPreviewUpdate(_ request: TaskBoardUpdateItemRequest) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: schemaVersion,
      id: id,
      title: request.title ?? title,
      body: request.body ?? body,
      status: request.status ?? status,
      priority: request.priority ?? priority,
      tags: request.tags ?? tags,
      projectId: request.clearProjectId ? nil : request.projectId ?? projectId,
      agentMode: request.agentMode ?? agentMode,
      externalRefs: request.externalRefs ?? externalRefs,
      planning: request.planning ?? planning,
      workflow: request.workflow ?? workflow,
      sessionId: request.clearSessionId ? nil : request.sessionId ?? sessionId,
      workItemId: request.clearWorkItemId ? nil : request.workItemId ?? workItemId,
      usage: usage,
      createdAt: createdAt,
      updatedAt: PreviewHarnessClientState.mutationTimestamp,
      deletedAt: deletedAt
    )
  }
}
