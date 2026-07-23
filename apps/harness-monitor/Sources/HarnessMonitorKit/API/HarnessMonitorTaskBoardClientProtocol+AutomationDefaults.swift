import Foundation

extension HarnessMonitorTaskBoardClientProtocol {
  public func taskBoardAutomationRuns(
    request _: TaskBoardAutomationHistoryRequest
  ) async throws -> TaskBoardAutomationHistoryResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board automation unavailable")
  }

  public func taskBoardAutomationRunDetail(
    runID _: String
  ) async throws -> TaskBoardAutomationRunDetail {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board automation unavailable")
  }

  public func taskBoardAutomationMetrics() async throws -> TaskBoardAutomationMetrics {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board automation unavailable")
  }

  public func forceCancelTaskBoardAutomation(
    request _: TaskBoardAutomationForceCancelRequest
  ) async throws -> TaskBoardAutomationForceCancelResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board automation unavailable")
  }
}
