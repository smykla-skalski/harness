import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardItemTriageCurrent(id: String) async throws -> TaskBoardTriageCurrentResponse
  {
    let id = try taskBoardPathSegment(id)
    return try await get(
      "/v1/task-board/items/\(id)/triage", decoder: PolicyWireCoding.decoder
    )
  }

  public func taskBoardItemTriageHistory(
    id: String,
    beforeGeneration: UInt64? = nil,
    limit: UInt32? = nil
  ) async throws -> TaskBoardTriageHistoryResponse {
    let id = try taskBoardPathSegment(id)
    var queryItems: [URLQueryItem] = []
    if let beforeGeneration {
      queryItems.append(URLQueryItem(name: "before_generation", value: String(beforeGeneration)))
    }
    if let limit {
      queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    return try await get(
      "/v1/task-board/items/\(id)/triage/history",
      queryItems: queryItems,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func setTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardSetTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    let id = try taskBoardPathSegment(id)
    let wire: TaskBoardTriageOverrideMutationResponseWire = try await put(
      "/v1/task-board/items/\(id)/triage/override", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardTriageOverrideMutationResponse(wire: wire)
  }

  public func clearTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardClearTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    let id = try taskBoardPathSegment(id)
    let wire: TaskBoardTriageOverrideMutationResponseWire = try await post(
      "/v1/task-board/items/\(id)/triage/override/clear", body: request,
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardTriageOverrideMutationResponse(wire: wire)
  }

}
