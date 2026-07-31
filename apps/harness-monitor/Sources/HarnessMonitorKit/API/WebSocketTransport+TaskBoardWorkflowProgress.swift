import Foundation

extension WebSocketTransport {
  public func taskBoardItemWorkflowProgress(id: String) async throws
    -> TaskBoardWorkflowProgressResponse
  {
    let value = try await rpc(
      method: .taskBoardWorkflowProgressGet,
      params: .object(["id": .string(id)])
    )
    return try decodePolicyWire(value)
  }
}
