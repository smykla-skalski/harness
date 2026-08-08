import Foundation

extension PreviewHarnessClient {
  public func taskBoardItemProgress(id: String) async throws
    -> TaskBoardWorkItemProgressResponse
  {
    try await performActionDelay()
    return try await state.taskBoardItemProgress(id: id)
  }
}
