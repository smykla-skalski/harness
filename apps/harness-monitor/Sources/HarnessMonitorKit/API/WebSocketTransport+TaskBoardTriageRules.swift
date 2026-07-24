import Foundation

extension WebSocketTransport {
  public func taskBoardTriageRulesDraft() async throws -> TaskBoardTriageRulesDraftResponse {
    let value = try await rpc(method: .taskBoardTriageRulesDraftGet, params: .object([:]))
    return try decodePolicyWire(value)
  }

  public func saveTaskBoardTriageRulesDraft(
    request: TaskBoardSaveTriageRulesDraftRequest
  ) async throws -> TriageRuleSetDraftSaveResult {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardTriageRulesDraftSave, params: params)
    return try decodePolicyWire(value)
  }

  public func previewTaskBoardTriageRules(
    request: TaskBoardPreviewTriageRulesRequest
  ) async throws -> TriageRuleSetPreviewResult {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardTriageRulesPreview, params: params)
    return try decodePolicyWire(value)
  }

  public func activateTaskBoardTriageRules(
    request: TaskBoardActivateTriageRulesRequest
  ) async throws -> TriageRuleSetActivationResult {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardTriageRulesActivate, params: params)
    return try decodePolicyWire(value)
  }

  public func taskBoardTriageRulesRevisions(limit: UInt32? = nil) async throws
    -> TaskBoardTriageRulesRevisionsResponse
  {
    var params: [String: JSONValue] = [:]
    if let limit {
      params["limit"] = .number(Double(limit))
    }
    let value = try await rpc(method: .taskBoardTriageRulesRevisions, params: .object(params))
    return try decodePolicyWire(value)
  }

  public func taskBoardTriageRulesAudit(limit: UInt32? = nil) async throws
    -> TaskBoardTriageRulesAuditResponse
  {
    var params: [String: JSONValue] = [:]
    if let limit {
      params["limit"] = .number(Double(limit))
    }
    let value = try await rpc(method: .taskBoardTriageRulesAudit, params: .object(params))
    return try decodePolicyWire(value)
  }
}
