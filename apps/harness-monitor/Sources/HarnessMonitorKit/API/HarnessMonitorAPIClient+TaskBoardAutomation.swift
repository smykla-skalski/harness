import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardAutomationRuns(
    request: TaskBoardAutomationHistoryRequest
  ) async throws -> TaskBoardAutomationHistoryResponse {
    var queryItems: [URLQueryItem] = []
    if let limit = request.limit {
      queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    if let before = request.before {
      queryItems.append(URLQueryItem(name: "before", value: before))
    }
    return try await get(
      "/v1/task-board/orchestrator/runs",
      queryItems: queryItems,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func taskBoardAutomationRunDetail(
    runID: String
  ) async throws -> TaskBoardAutomationRunDetail {
    let encodedRunID = try taskBoardPathSegment(runID)
    return try await get(
      "/v1/task-board/orchestrator/runs/\(encodedRunID)",
      decoder: PolicyWireCoding.decoder
    )
  }

  public func taskBoardAutomationMetrics() async throws -> TaskBoardAutomationMetrics {
    try await get(
      "/v1/task-board/orchestrator/metrics",
      decoder: PolicyWireCoding.decoder
    )
  }

  public func forceCancelTaskBoardAutomation(
    request: TaskBoardAutomationForceCancelRequest
  ) async throws -> TaskBoardAutomationForceCancelResponse {
    try await post(
      "/v1/task-board/orchestrator/force-cancel",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

}
