import Foundation

extension WebSocketTransport {
  public func taskBoardItemsSnapshot(
    status: TaskBoardStatus? = nil
  ) async throws -> TaskBoardListItemsSnapshot {
    let params = try encodeParams(TaskBoardListItemsRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardList, params: params)
    let wire: TaskBoardListItemsResponseWire = try decodePolicyWire(value)
    return TaskBoardListItemsSnapshot(wire: wire)
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
