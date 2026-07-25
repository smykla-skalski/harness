import Foundation

extension WebSocketTransport: TaskBoardItemPageSource {
  func taskBoardItemPage(
    status: TaskBoardStatus?,
    cursor: String?
  ) async throws -> TaskBoardListItemsResponseWire {
    let params = try encodeParams(
      TaskBoardListItemsRequest(status: status, cursor: cursor), extra: [:]
    )
    let value = try await rpc(method: .taskBoardList, params: params)
    return try decodePolicyWire(value)
  }

  public func taskBoardItemsSnapshot(
    status: TaskBoardStatus? = nil
  ) async throws -> TaskBoardListItemsSnapshot {
    TaskBoardListItemsSnapshot(wire: try await mergedTaskBoardItemPages(status: status))
  }

  public func taskBoardItemPositionSnapshot(id: String) async throws
    -> TaskBoardItemPositionSnapshot
  {
    let value = try await rpc(method: .taskBoardPositionGet, params: .object(["id": .string(id)]))
    let wire: TaskBoardItemPositionSnapshotWire = try decodePolicyWire(value)
    return TaskBoardItemPositionSnapshot(wire: wire)
  }

  public func setTaskBoardItemPosition(
    id: String,
    request: TaskBoardSetItemPositionRequest
  ) async throws -> TaskBoardItemPositionMutationResponse {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardPositionSet, params: params)
    let wire: TaskBoardItemPositionMutationResponseWire = try decodePolicyWire(value)
    return TaskBoardItemPositionMutationResponse(wire: wire)
  }

  public func resetTaskBoardItemPosition(
    id: String,
    request: TaskBoardResetItemPositionRequest
  ) async throws -> TaskBoardItemPositionMutationResponse {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardPositionReset, params: params)
    let wire: TaskBoardItemPositionMutationResponseWire = try decodePolicyWire(value)
    return TaskBoardItemPositionMutationResponse(wire: wire)
  }
}
