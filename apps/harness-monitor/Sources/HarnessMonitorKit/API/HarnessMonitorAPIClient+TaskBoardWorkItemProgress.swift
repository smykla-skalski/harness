import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardItemProgress(id: String) async throws
    -> TaskBoardWorkItemProgressResponse
  {
    let id = try taskBoardPathSegment(id)
    return try await get(
      "/v1/task-board/items/\(id)/progress",
      decoder: PolicyWireCoding.decoder
    )
  }
}
