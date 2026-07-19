import Foundation

extension HarnessMonitorTaskBoardClientProtocol {
  public func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func runTaskBoardOrchestratorOnce(
    request _: TaskBoardOrchestratorRunOnceRequest
  ) async throws -> TaskBoardOrchestratorRunOnceResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func runTaskBoardOrchestratorOnce() async throws -> TaskBoardOrchestratorRunOnceResponse {
    try await runTaskBoardOrchestratorOnce(request: TaskBoardOrchestratorRunOnceRequest())
  }

  public func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func updateTaskBoardOrchestratorSettings(
    request _: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }
}
