import Foundation

extension HarnessMonitorTaskBoardClientProtocol {
  public func taskBoardItemProgress(id _: String) async throws
    -> TaskBoardWorkItemProgressResponse
  {
    throw HarnessMonitorAPIError.server(
      code: 501,
      message: "Task board worker progress unavailable"
    )
  }
}
