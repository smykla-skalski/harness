import Foundation

extension PreviewHarnessClient {
  public func taskBoardItemsSnapshot(
    status: TaskBoardStatus? = nil
  ) async throws -> TaskBoardListItemsSnapshot {
    try await performActionDelay()
    return await state.taskBoardItemsSnapshot(status: status)
  }

  public func taskBoardItemPositionSnapshot(id: String) async throws
    -> TaskBoardItemPositionSnapshot
  {
    try await performActionDelay()
    return try await state.taskBoardItemPositionSnapshot(id: id)
  }

  public func setTaskBoardItemPosition(
    id: String,
    request: TaskBoardSetItemPositionRequest
  ) async throws -> TaskBoardItemPositionMutationResponse {
    try await performActionDelay()
    return try await state.setTaskBoardItemPosition(id: id, request: request)
  }

  public func resetTaskBoardItemPosition(
    id: String,
    request: TaskBoardResetItemPositionRequest
  ) async throws -> TaskBoardItemPositionMutationResponse {
    try await performActionDelay()
    return try await state.resetTaskBoardItemPosition(id: id, request: request)
  }
}
