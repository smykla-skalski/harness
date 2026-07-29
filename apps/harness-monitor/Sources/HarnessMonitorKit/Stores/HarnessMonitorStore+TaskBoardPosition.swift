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
