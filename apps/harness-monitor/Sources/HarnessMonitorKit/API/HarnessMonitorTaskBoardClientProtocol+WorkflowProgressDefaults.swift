import Foundation

extension HarnessMonitorTaskBoardClientProtocol {
  public func taskBoardItemWorkflowProgress(id _: String) async throws
    -> TaskBoardWorkflowProgressResponse
  {
    throw HarnessMonitorAPIError.server(
      code: 501,
      message: "Task board workflow progress unavailable"
    )
  }
}
