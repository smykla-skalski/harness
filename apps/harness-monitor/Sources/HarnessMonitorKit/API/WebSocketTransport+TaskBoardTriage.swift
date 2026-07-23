import Foundation

extension WebSocketTransport {
  public func taskBoardItemTriageCurrent(id: String) async throws
    -> TaskBoardTriageCurrentResponse
  {
    let value = try await rpc(method: .taskBoardTriageGet, params: .object(["id": .string(id)]))
    return try decodePolicyWire(value)
  }

  public func taskBoardItemTriageHistory(
    id: String,
    beforeGeneration: UInt64? = nil,
    limit: UInt32? = nil
  ) async throws -> TaskBoardTriageHistoryResponse {
    var params: [String: JSONValue] = ["id": .string(id)]
    if let beforeGeneration {
      params["before_generation"] = .string(String(beforeGeneration))
    }
    if let limit {
      params["limit"] = .number(Double(limit))
    }
    let value = try await rpc(method: .taskBoardTriageHistory, params: .object(params))
    return try decodePolicyWire(value)
  }

  public func setTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardSetTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardTriageOverrideSet, params: params)
    let wire: TaskBoardTriageOverrideMutationResponseWire = try decodePolicyWire(value)
    return TaskBoardTriageOverrideMutationResponse(wire: wire)
  }

  public func clearTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardClearTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardTriageOverrideClear, params: params)
    let wire: TaskBoardTriageOverrideMutationResponseWire = try decodePolicyWire(value)
    return TaskBoardTriageOverrideMutationResponse(wire: wire)
  }
}
