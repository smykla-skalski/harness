import Foundation

extension HarnessMonitorStore {
  public func taskBoardItemReviewReport(id: String) async -> TaskBoardAiReviewReportResponse? {
    await readTaskBoard { client in
      try await client.taskBoardItemReviewReport(id: id)
    }
  }
}
