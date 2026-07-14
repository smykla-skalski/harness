import Foundation

// Policy canvas and policy pipeline API endpoints.
extension HarnessMonitorAPIClient {
  public func policyCanvasWorkspace() async throws -> PolicyCanvasWorkspace {
    try await get("/v1/policy-canvases", decoder: PolicyWireCoding.decoder)
  }

  public func createPolicyCanvas(
    request: PolicyCanvasCreateRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-canvases/create",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func duplicatePolicyCanvas(
    request: PolicyCanvasDuplicateRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-canvases/duplicate",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func renamePolicyCanvas(
    request: PolicyCanvasRenameRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-canvases/rename",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func activatePolicyCanvas(
    request: PolicyCanvasActivateRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-canvases/active",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func deletePolicyCanvas(
    request: PolicyCanvasDeleteRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-canvases/delete",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func setPolicyCanvasGlobalEnforcement(
    request: PolicyCanvasSetGlobalEnforcementRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-canvases/global-enforcement",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func setPolicyCanvasSpawnRequiresLivePolicy(
    request: PolicyCanvasSetSpawnRequiresLivePolicyRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-canvases/spawn-requires-live-policy",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func setPolicyCanvasSpawnKillSwitch(
    request: PolicyCanvasSetSpawnKillSwitchRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-canvases/spawn-kill-switch",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func policyApprovalGrants() async throws -> [PolicyApprovalGrant] {
    let response: PolicyApprovalGrantsListResponse = try await get(
      "/v1/policy-approval-grants", decoder: PolicyWireCoding.decoder
    )
    return response.grants
  }

  public func resolvePolicyApprovalGrant(
    request: PolicyApprovalGrantResolveRequest
  ) async throws -> PolicyApprovalGrant {
    let response: PolicyApprovalGrantResolveResponse = try await post(
      "/v1/policy-approval-grants/resolve",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
    return response.grant
  }

  public func createPolicyScenario(
    request: PolicyScenarioCreateRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-scenarios/create",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func updatePolicyScenario(
    request: PolicyScenarioUpdateRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-scenarios/update",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func deletePolicyScenario(
    request: PolicyScenarioDeleteRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-scenarios/delete",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func resetPolicyScenarios(
    request: PolicyScenarioResetRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-scenarios/reset",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func policyPipeline(
    canvasId: String? = nil
  ) async throws -> PolicyPipelineDocument {
    try await get(
      "/v1/policy-pipeline",
      queryItems: policyCanvasQueryItems(canvasId: canvasId),
      decoder: PolicyWireCoding.decoder
    )
  }

  public func savePolicyPipelineDraft(
    request: PolicyPipelineSaveDraftRequest
  ) async throws -> PolicyPipelineSaveDraftResponse {
    try await put(
      "/v1/policy-pipeline",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func simulatePolicyPipeline(
    request: PolicyPipelineSimulateRequest
  ) async throws -> PolicyPipelineSimulationResult {
    let wire: PolicyPipelineSimulationResultWire = try await post(
      "/v1/policy-pipeline/simulate",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
    return PolicyPipelineSimulationResult(wire: wire)
  }

  public func promotePolicyPipeline(
    request: PolicyPipelinePromoteRequest
  ) async throws -> PolicyPipelinePromoteResponse {
    try await post(
      "/v1/policy-pipeline/promote",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func makeLivePolicyPipeline(
    request: PolicyPipelineMakeLiveRequest
  ) async throws -> PolicyPipelineMakeLiveResponse {
    try await post(
      "/v1/policy-pipeline/make-live",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func goLiveDiffPolicyPipeline(
    request: PolicyPipelineGoLiveDiffRequest
  ) async throws -> PolicyPipelineGoLiveDiff {
    try await post(
      "/v1/policy-pipeline/go-live-diff",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func replayPolicyPipeline(
    request: PolicyPipelineReplayRequest
  ) async throws -> PolicyPipelineReplayResult {
    try await post(
      "/v1/policy-pipeline/replay",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func policyPipelineAudit(
    canvasId: String? = nil
  ) async throws -> PolicyPipelineAuditSummary {
    let wire: PolicyPipelineAuditSummaryWire = try await get(
      "/v1/policy-pipeline/audit",
      queryItems: policyCanvasQueryItems(canvasId: canvasId),
      decoder: PolicyWireCoding.decoder
    )
    return PolicyPipelineAuditSummary(wire: wire)
  }

  public func exportPolicyCanvas(
    request: PolicyCanvasExportRequest
  ) async throws -> PolicyCanvasExportResponse {
    try await post(
      "/v1/policy-canvases/export",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func importPolicyCanvas(
    request: PolicyCanvasImportRequest
  ) async throws -> PolicyCanvasWorkspace {
    try await post(
      "/v1/policy-canvases/import",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  func policyCanvasQueryItems(canvasId: String?) -> [URLQueryItem] {
    guard let canvasId else {
      return []
    }
    return [URLQueryItem(name: "canvas_id", value: canvasId)]
  }
}
