import Foundation

extension PreviewHarnessClient {
  public func taskBoardItemWorkflowProgress(id: String) async throws
    -> TaskBoardWorkflowProgressResponse
  {
    try await performActionDelay()
    return try await state.taskBoardItemWorkflowProgress(id: id)
  }
}
