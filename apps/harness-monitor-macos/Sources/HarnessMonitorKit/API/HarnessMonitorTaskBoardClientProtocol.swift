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
  func evaluateTaskBoard(request: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
  func auditTaskBoard(status: TaskBoardStatus?) async throws -> TaskBoardAuditSummary
  func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus
  func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus
  func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus
  func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest
  ) async throws -> TaskBoardOrchestratorRunOnceResponse
  func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings
  func updateTaskBoardOrchestratorSettings(
    request: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings
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

  public func evaluateTaskBoard(request _: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
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

  public func evaluateTaskBoard(
    status: TaskBoardStatus? = nil,
    dryRun: Bool = false
  ) async throws -> TaskBoardEvaluationSummary {
    try await evaluateTaskBoard(request: TaskBoardEvaluateRequest(status: status, dryRun: dryRun))
  }

  public func auditTaskBoard(status _: TaskBoardStatus?) async throws -> TaskBoardAuditSummary {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func runTaskBoardOrchestratorOnce(
    request _: TaskBoardOrchestratorRunOnceRequest
  ) async throws -> TaskBoardOrchestratorRunOnceResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func updateTaskBoardOrchestratorSettings(
    request _: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable.")
  }

  public func runTaskBoardOrchestratorOnce() async throws -> TaskBoardOrchestratorRunOnceResponse {
    try await runTaskBoardOrchestratorOnce(request: TaskBoardOrchestratorRunOnceRequest())
  }
}
