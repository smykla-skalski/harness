import Foundation

extension WebSocketTransport {
  public func taskBoardItemProgress(id: String) async throws
    -> TaskBoardWorkItemProgressResponse
  {
    let value = try await rpc(
      method: .taskBoardProgressGet,
      params: .object(["id": .string(id)])
    )
    return try decodePolicyWire(value)
  }
}
