import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardTriageRulesDraft() async throws -> TaskBoardTriageRulesDraftResponse {
    try await get("/v1/task-board/triage/rules/draft", decoder: PolicyWireCoding.decoder)
  }

  public func saveTaskBoardTriageRulesDraft(
    request: TaskBoardSaveTriageRulesDraftRequest
  ) async throws -> TriageRuleSetDraftSaveResult {
    try await put(
      "/v1/task-board/triage/rules/draft", body: request, decoder: PolicyWireCoding.decoder
    )
  }

  public func previewTaskBoardTriageRules(
    request: TaskBoardPreviewTriageRulesRequest
  ) async throws -> TriageRuleSetPreviewResult {
    try await post(
      "/v1/task-board/triage/rules/preview", body: request, decoder: PolicyWireCoding.decoder
    )
  }

  public func activateTaskBoardTriageRules(
    request: TaskBoardActivateTriageRulesRequest
  ) async throws -> TriageRuleSetActivationResult {
    try await post(
      "/v1/task-board/triage/rules/activate", body: request, decoder: PolicyWireCoding.decoder
    )
  }

  public func taskBoardTriageRulesRevisions(limit: UInt32? = nil) async throws
    -> TaskBoardTriageRulesRevisionsResponse
  {
    var queryItems: [URLQueryItem] = []
    if let limit {
      queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    return try await get(
      "/v1/task-board/triage/rules/revisions", queryItems: queryItems,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func taskBoardTriageRulesAudit(limit: UInt32? = nil) async throws
    -> TaskBoardTriageRulesAuditResponse
  {
    var queryItems: [URLQueryItem] = []
    if let limit {
      queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    return try await get(
      "/v1/task-board/triage/rules/audit", queryItems: queryItems, decoder: PolicyWireCoding.decoder
    )
  }
}
