import Foundation

extension HarnessMonitorTaskBoardClientProtocol {
  public func taskBoardItemTriageCurrent(id _: String) async throws
    -> TaskBoardTriageCurrentResponse
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board triage unavailable")
  }

  public func taskBoardItemTriageHistory(
    id _: String,
    beforeGeneration _: UInt64?,
    limit _: UInt32?
  ) async throws -> TaskBoardTriageHistoryResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board triage unavailable")
  }

  public func setTaskBoardItemTriageOverride(
    id _: String,
    request _: TaskBoardSetTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board triage unavailable")
  }

  public func clearTaskBoardItemTriageOverride(
    id _: String,
    request _: TaskBoardClearTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board triage unavailable")
  }
}
