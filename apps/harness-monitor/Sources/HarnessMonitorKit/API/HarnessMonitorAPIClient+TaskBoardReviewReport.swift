import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardItemReviewReport(id: String) async throws
    -> TaskBoardAiReviewReportResponse
  {
    let id = try taskBoardPathSegment(id)
    return try await get(
      "/v1/task-board/items/\(id)/review-report",
      decoder: PolicyWireCoding.decoder
    )
  }

}
