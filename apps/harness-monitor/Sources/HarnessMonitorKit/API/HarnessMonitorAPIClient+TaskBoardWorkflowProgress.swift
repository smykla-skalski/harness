import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardItemWorkflowProgress(id: String) async throws
    -> TaskBoardWorkflowProgressResponse
  {
    let id = try taskBoardWorkflowProgressPathSegment(id)
    return try await get(
      "/v1/task-board/items/\(id)/workflow-progress",
      decoder: PolicyWireCoding.decoder
    )
  }

  private func taskBoardWorkflowProgressPathSegment(_ value: String) throws -> String {
    guard
      !value.isEmpty,
      !value.contains("/"),
      !value.contains("\\"),
      !value.contains("..")
    else {
      throw HarnessMonitorAPIError.invalidEndpoint(value)
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw HarnessMonitorAPIError.invalidEndpoint(value)
    }
    return encoded
  }
}
