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

  public func taskBoardTriageRulesDraft() async throws -> TaskBoardTriageRulesDraftResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board triage rules unavailable")
  }

  public func saveTaskBoardTriageRulesDraft(
    request _: TaskBoardSaveTriageRulesDraftRequest
  ) async throws -> TriageRuleSetDraftSaveResult {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board triage rules unavailable")
  }

  public func previewTaskBoardTriageRules(
    request _: TaskBoardPreviewTriageRulesRequest
  ) async throws -> TriageRuleSetPreviewResult {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board triage rules unavailable")
  }

  public func activateTaskBoardTriageRules(
    request _: TaskBoardActivateTriageRulesRequest
  ) async throws -> TriageRuleSetActivationResult {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board triage rules unavailable")
  }

  public func taskBoardTriageRulesRevisions(limit _: UInt32?) async throws
    -> TaskBoardTriageRulesRevisionsResponse
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board triage rules unavailable")
  }

  public func taskBoardTriageRulesAudit(limit _: UInt32?) async throws
    -> TaskBoardTriageRulesAuditResponse
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board triage rules unavailable")
  }
}
