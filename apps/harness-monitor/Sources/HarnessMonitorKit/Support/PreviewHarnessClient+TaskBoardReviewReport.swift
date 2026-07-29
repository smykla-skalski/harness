import Foundation

extension PreviewHarnessClient {
  public func taskBoardItemReviewReport(id: String) async throws
    -> TaskBoardAiReviewReportResponse
  {
    try await performActionDelay()
    return try await state.taskBoardItemReviewReport(id: id)
  }
}
