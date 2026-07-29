import Foundation

extension HarnessMonitorTaskBoardClientProtocol {
  public func taskBoardItemReviewReport(id _: String) async throws
    -> TaskBoardAiReviewReportResponse
  {
    throw HarnessMonitorAPIError.server(
      code: 501,
      message: "Task board review reports unavailable"
    )
  }
}
