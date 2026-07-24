import Foundation

extension PreviewHarnessClient {
  public func taskBoardTriageRulesDraft() async throws -> TaskBoardTriageRulesDraftResponse {
    try await performActionDelay()
    return await state.taskBoardTriageRulesDraft()
  }

  public func saveTaskBoardTriageRulesDraft(
    request: TaskBoardSaveTriageRulesDraftRequest
  ) async throws -> TriageRuleSetDraftSaveResult {
    try await performActionDelay()
    return await state.saveTaskBoardTriageRulesDraft(request: request)
  }

  public func previewTaskBoardTriageRules(
    request: TaskBoardPreviewTriageRulesRequest
  ) async throws -> TriageRuleSetPreviewResult {
    try await performActionDelay()
    return await state.previewTaskBoardTriageRules(request: request)
  }

  public func activateTaskBoardTriageRules(
    request: TaskBoardActivateTriageRulesRequest
  ) async throws -> TriageRuleSetActivationResult {
    try await performActionDelay()
    return await state.activateTaskBoardTriageRules(request: request)
  }

  public func taskBoardTriageRulesRevisions(limit: UInt32? = nil) async throws
    -> TaskBoardTriageRulesRevisionsResponse
  {
    try await performActionDelay()
    return await state.taskBoardTriageRulesRevisions(limit: limit)
  }

  public func taskBoardTriageRulesAudit(limit: UInt32? = nil) async throws
    -> TaskBoardTriageRulesAuditResponse
  {
    try await performActionDelay()
    return await state.taskBoardTriageRulesAudit(limit: limit)
  }
}
