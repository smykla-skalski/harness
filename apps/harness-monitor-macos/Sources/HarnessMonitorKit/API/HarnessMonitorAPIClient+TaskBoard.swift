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

  public func auditTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardAuditSummary {
    try await get(
      "/v1/task-board/audit",
      queryItems: taskBoardQueryItems(status: status)
    )
  }

  private func taskBoardQueryItems(status: TaskBoardStatus?) -> [URLQueryItem] {
    guard let status else {
      return []
    }
    return [URLQueryItem(name: "status", value: status.rawValue)]
  }
}
