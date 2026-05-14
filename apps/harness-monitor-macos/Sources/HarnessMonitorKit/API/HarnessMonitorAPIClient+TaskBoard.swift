import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardItems(status: TaskBoardStatus? = nil) async throws -> [TaskBoardItem] {
    let response: TaskBoardListItemsResponse = try await get(
      "/v1/task-board/items",
      queryItems: taskBoardQueryItems(status: status)
    )
    return response.items
  }

  public func taskBoardItem(id: String) async throws -> TaskBoardItem {
    try await get("/v1/task-board/items/\(id)")
  }

  public func createTaskBoardItem(
    request: TaskBoardCreateItemRequest
  ) async throws -> TaskBoardItem {
    try await post("/v1/task-board/items", body: request)
  }

  public func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    try await put("/v1/task-board/items/\(id)", body: request)
  }

  public func deleteTaskBoardItem(id: String) async throws -> TaskBoardItem {
    try await delete("/v1/task-board/items/\(id)")
  }

  public func syncTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardSyncSummary {
    try await post("/v1/task-board/sync", body: TaskBoardStatusFilterRequest(status: status))
  }

  public func dispatchTaskBoard(request: TaskBoardDispatchRequest) async throws
    -> TaskBoardDispatchSummary
  {
    try await post("/v1/task-board/dispatch", body: request)
  }

  public func evaluateTaskBoard(request: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
  {
    try await post("/v1/task-board/evaluate", body: request)
  }

  public func auditTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardAuditSummary {
    try await get(
      "/v1/task-board/audit",
      queryItems: taskBoardQueryItems(status: status)
    )
  }

  public func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    try await get("/v1/task-board/orchestrator/status")
  }

  public func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    try await post("/v1/task-board/orchestrator/start", body: EmptyBody())
  }

  public func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    try await post("/v1/task-board/orchestrator/stop", body: EmptyBody())
  }

  public func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest = TaskBoardOrchestratorRunOnceRequest()
  ) async throws
    -> TaskBoardOrchestratorRunOnceResponse
  {
    try await post("/v1/task-board/orchestrator/run-once", body: request)
  }

  public func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    try await get("/v1/task-board/orchestrator/settings")
  }

  public func updateTaskBoardOrchestratorSettings(
    request: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    try await put("/v1/task-board/orchestrator/settings", body: request)
  }

  private func taskBoardQueryItems(status: TaskBoardStatus?) -> [URLQueryItem] {
    guard let status else {
      return []
    }
    return [URLQueryItem(name: "status", value: status.rawValue)]
  }
}
