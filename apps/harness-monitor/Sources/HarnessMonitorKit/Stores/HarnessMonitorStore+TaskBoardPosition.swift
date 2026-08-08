import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func setTaskBoardItemPosition(
    id: String,
    request: TaskBoardSetItemPositionRequest
  ) async -> Bool {
    await mutateTaskBoardPosition { client in
      try await client.setTaskBoardItemPosition(id: id, request: request)
    }
  }

  @discardableResult
  public func resetTaskBoardItemPosition(
    id: String,
    request: TaskBoardResetItemPositionRequest
  ) async -> Bool {
    await mutateTaskBoardPosition { client in
      try await client.resetTaskBoardItemPosition(id: id, request: request)
    }
  }

  private func mutateTaskBoardPosition(
    operation:
      @escaping @Sendable (any HarnessMonitorClientProtocol) async throws
      -> TaskBoardItemPositionMutationResponse
  ) async -> Bool {
    guard let client else { return false }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }
    do {
      let response = try await Self.measureOperation { try await operation(client) }.value
      recordRequestSuccess()
      mergeTaskBoardItem(response.snapshot.item)
      await refreshTaskBoardDashboardSnapshot(using: client)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}

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

  func hasSameTaskBoardPosition(as other: TaskBoardItem) -> Bool {
    status == other.status
      && lanePosition == other.lanePosition
      && laneOrigin == other.laneOrigin
      && laneSetAt == other.laneSetAt
  }

  func withTaskBoardPosition(
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
      workspaceId: workspaceId,
      workingCopyId: workingCopyId,
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
