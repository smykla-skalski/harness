import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardItemsSnapshot(
    status: TaskBoardStatus? = nil
  ) async throws -> TaskBoardListItemsSnapshot {
    let wire: TaskBoardListItemsResponseWire = try await get(
      "/v1/task-board/items",
      queryItems: taskBoardQueryItems(status: status),
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardListItemsSnapshot(wire: wire)
  }

  public func taskBoardItemPositionSnapshot(id: String) async throws
    -> TaskBoardItemPositionSnapshot
  {
    let wire: TaskBoardItemPositionSnapshotWire = try await get(
      "/v1/task-board/items/\(id)/position", decoder: PolicyWireCoding.decoder
    )
    return TaskBoardItemPositionSnapshot(wire: wire)
  }

  public func setTaskBoardItemPosition(
    id: String,
    request: TaskBoardSetItemPositionRequest
  ) async throws -> TaskBoardItemPositionMutationResponse {
    let wire: TaskBoardItemPositionMutationResponseWire = try await put(
      "/v1/task-board/items/\(id)/position", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardItemPositionMutationResponse(wire: wire)
  }

  public func resetTaskBoardItemPosition(
    id: String,
    request: TaskBoardResetItemPositionRequest
  ) async throws -> TaskBoardItemPositionMutationResponse {
    let wire: TaskBoardItemPositionMutationResponseWire = try await post(
      "/v1/task-board/items/\(id)/position/reset", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardItemPositionMutationResponse(wire: wire)
  }
}
