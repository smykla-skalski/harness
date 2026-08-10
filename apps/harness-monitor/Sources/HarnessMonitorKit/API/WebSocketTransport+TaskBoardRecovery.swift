import Foundation

extension WebSocketTransport {
  public func cancelTaskBoardSync(
    recoveryTimeout: Duration
  ) async throws -> TaskBoardSyncCancelResponse {
    let value = try await rpc(
      method: .taskBoardSyncCancel,
      params: .object([:]),
      timeout: recoveryTimeout
    )
    return try decodePolicyWire(value)
  }

  public func taskBoardSyncStatus(
    recoveryTimeout: Duration
  ) async throws -> TaskBoardSyncStatusResponse {
    let value = try await rpc(
      method: .taskBoardSyncStatus,
      params: .object([:]),
      timeout: recoveryTimeout
    )
    let wire: TaskBoardSyncStatusResponseWire = try decodePolicyWire(value)
    return TaskBoardSyncStatusResponse(wire: wire)
  }
}
