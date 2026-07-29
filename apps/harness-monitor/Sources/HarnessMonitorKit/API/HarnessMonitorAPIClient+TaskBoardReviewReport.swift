import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardItemReviewReport(id: String) async throws
    -> TaskBoardAiReviewReportResponse
  {
    let id = try taskBoardReviewReportPathSegment(id)
    return try await get(
      "/v1/task-board/items/\(id)/review-report",
      decoder: PolicyWireCoding.decoder
    )
  }

  private func taskBoardReviewReportPathSegment(_ value: String) throws -> String {
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
