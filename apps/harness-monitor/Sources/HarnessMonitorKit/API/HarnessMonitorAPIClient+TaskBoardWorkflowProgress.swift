import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardItemWorkflowProgress(id: String) async throws
    -> TaskBoardWorkflowProgressResponse
  {
    let id = try taskBoardPathSegment(id)
    return try await get(
      "/v1/task-board/items/\(id)/workflow-progress",
      decoder: PolicyWireCoding.decoder
    )
  }

}
