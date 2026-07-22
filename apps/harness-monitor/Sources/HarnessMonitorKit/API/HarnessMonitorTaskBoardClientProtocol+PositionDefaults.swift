import Foundation

extension HarnessMonitorTaskBoardClientProtocol {
  public func taskBoardItemsSnapshot(status _: TaskBoardStatus?) async throws
    -> TaskBoardListItemsSnapshot
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board item snapshot unavailable")
  }

  public func taskBoardItemPositionSnapshot(id _: String) async throws
    -> TaskBoardItemPositionSnapshot
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board positions unavailable")
  }

  public func setTaskBoardItemPosition(
    id _: String,
    request _: TaskBoardSetItemPositionRequest
  ) async throws -> TaskBoardItemPositionMutationResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board positions unavailable")
  }

  public func resetTaskBoardItemPosition(
    id _: String,
    request _: TaskBoardResetItemPositionRequest
  ) async throws -> TaskBoardItemPositionMutationResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board positions unavailable")
  }
}
