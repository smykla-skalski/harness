import Foundation

extension WebSocketTransport {
  public func taskBoardItemReviewReport(id: String) async throws
    -> TaskBoardAiReviewReportResponse
  {
    let value = try await rpc(
      method: .taskBoardReviewReportGet,
      params: .object(["id": .string(id)])
    )
    return try decodePolicyWire(value)
  }
}
