import Foundation

extension WebSocketTransport {
  public func taskBoardAutomationRuns(
    request: TaskBoardAutomationHistoryRequest
  ) async throws -> TaskBoardAutomationHistoryResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorRuns, params: params)
    return try decodePolicyWire(value)
  }

  public func taskBoardAutomationRunDetail(
    runID: String
  ) async throws -> TaskBoardAutomationRunDetail {
    let params = try encodeParams(
      TaskBoardAutomationRunDetailRequest(runId: runID),
      extra: [:]
    )
    let value = try await rpc(method: .taskBoardOrchestratorRunDetail, params: params)
    return try decodePolicyWire(value)
  }

  public func taskBoardAutomationMetrics() async throws -> TaskBoardAutomationMetrics {
    let value = try await rpc(method: .taskBoardOrchestratorMetrics)
    return try decodePolicyWire(value)
  }
}
