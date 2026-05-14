import Foundation

public protocol HarnessMonitorTaskBoardClientProtocol: Sendable {
  func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem]
  func taskBoardItem(id: String) async throws -> TaskBoardItem
  func createTaskBoardItem(request: TaskBoardCreateItemRequest) async throws -> TaskBoardItem
  func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem
  func deleteTaskBoardItem(id: String) async throws -> TaskBoardItem
  func syncTaskBoard(status: TaskBoardStatus?) async throws -> TaskBoardSyncSummary
  func dispatchTaskBoard(request: TaskBoardDispatchRequest) async throws -> TaskBoardDispatchSummary
  func auditTaskBoard(status: TaskBoardStatus?) async throws -> TaskBoardAuditSummary
}

extension HarnessMonitorTaskBoardClientProtocol {
  public func taskBoardItems(status _: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func taskBoardItem(id _: String) async throws -> TaskBoardItem {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func createTaskBoardItem(
    request _: TaskBoardCreateItemRequest
  ) async throws -> TaskBoardItem {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func updateTaskBoardItem(
    id _: String,
    request _: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func deleteTaskBoardItem(id _: String) async throws -> TaskBoardItem {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func syncTaskBoard(status _: TaskBoardStatus?) async throws -> TaskBoardSyncSummary {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func dispatchTaskBoard(request _: TaskBoardDispatchRequest) async throws
    -> TaskBoardDispatchSummary
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func dispatchTaskBoard(
    status: TaskBoardStatus? = nil,
    dryRun: Bool = true,
    projectDir: String? = nil
  ) async throws -> TaskBoardDispatchSummary {
    try await dispatchTaskBoard(
      request: TaskBoardDispatchRequest(status: status, dryRun: dryRun, projectDir: projectDir)
    )
  }

  public func auditTaskBoard(status _: TaskBoardStatus?) async throws -> TaskBoardAuditSummary {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }
}
