import Foundation

extension WebSocketTransport {
  public func taskBoardItems(status: TaskBoardStatus? = nil) async throws -> [TaskBoardItem] {
    let params = try encodeParams(TaskBoardListItemsRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardList, params: params)
    let response: TaskBoardListItemsResponse = try decode(value)
    return response.items
  }

  public func taskBoardItem(id: String) async throws -> TaskBoardItem {
    let value = try await rpc(
      method: .taskBoardGet,
      params: .object(["id": .string(id)])
    )
    return try decode(value)
  }

  public func createTaskBoardItem(
    request: TaskBoardCreateItemRequest
  ) async throws -> TaskBoardItem {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardCreate, params: params)
    return try decode(value)
  }

  public func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardUpdate, params: params)
    return try decode(value)
  }

  public func deleteTaskBoardItem(id: String) async throws -> TaskBoardItem {
    let value = try await rpc(
      method: .taskBoardDelete,
      params: .object(["id": .string(id)])
    )
    return try decode(value)
  }

  public func syncTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardSyncSummary {
    let params = try encodeParams(TaskBoardStatusFilterRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardSync, params: params)
    return try decode(value)
  }

  public func dispatchTaskBoard(request: TaskBoardDispatchRequest) async throws
    -> TaskBoardDispatchSummary
  {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardDispatch, params: params)
    return try decode(value)
  }

  public func evaluateTaskBoard(request: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
  {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardEvaluate, params: params)
    return try decode(value)
  }

  public func auditTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardAuditSummary {
    let params = try encodeParams(TaskBoardStatusFilterRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardAudit, params: params)
    return try decode(value)
  }

  public func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    let value = try await rpc(method: .taskBoardOrchestratorStatus)
    return try decode(value)
  }

  public func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    let value = try await rpc(method: .taskBoardOrchestratorStart)
    return try decode(value)
  }

  public func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    let value = try await rpc(method: .taskBoardOrchestratorStop)
    return try decode(value)
  }

  public func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest = TaskBoardOrchestratorRunOnceRequest()
  ) async throws
    -> TaskBoardOrchestratorRunOnceResponse
  {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorRunOnce, params: params)
    return try decode(value)
  }

  public func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    let value = try await rpc(method: .taskBoardOrchestratorSettingsGet)
    return try decode(value)
  }

  public func updateTaskBoardOrchestratorSettings(
    request: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorSettingsUpdate, params: params)
    return try decode(value)
  }
}
