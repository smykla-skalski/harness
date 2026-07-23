import Foundation

extension PreviewHarnessClient {
  public func taskBoardItemTriageCurrent(id: String) async throws
    -> TaskBoardTriageCurrentResponse
  {
    try await performActionDelay()
    return try await state.taskBoardItemTriageCurrent(id: id)
  }

  public func taskBoardItemTriageHistory(
    id: String,
    beforeGeneration: UInt64? = nil,
    limit: UInt32? = nil
  ) async throws -> TaskBoardTriageHistoryResponse {
    try await performActionDelay()
    return try await state.taskBoardItemTriageHistory(
      id: id,
      beforeGeneration: beforeGeneration,
      limit: limit
    )
  }

  public func setTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardSetTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    try await performActionDelay()
    return try await state.setTaskBoardItemTriageOverride(id: id, request: request)
  }

  public func clearTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardClearTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    try await performActionDelay()
    return try await state.clearTaskBoardItemTriageOverride(id: id, request: request)
  }
}
