import Foundation

extension PreviewHarnessClient {
  public func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    try await performActionDelay()
    return await state.currentTaskBoardItems(status: status)
  }

  public func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    try await performActionDelay()
    return try await state.updateTaskBoardItem(id: id, request: request)
  }

  public func syncTaskBoard(request _: TaskBoardSyncRequest) async throws -> TaskBoardSyncSummary {
    try await performActionDelay()
    return TaskBoardSyncSummary(total: 0, providers: [], operations: [])
  }
}
