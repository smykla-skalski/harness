import Foundation

// Policy canvas and policy pipeline task-board API endpoints.
extension HarnessMonitorAPIClient {
  public func taskBoardPolicyCanvasWorkspace() async throws -> TaskBoardPolicyCanvasWorkspace {
    try await get("/v1/task-board/policy/canvases", decoder: PolicyWireCoding.decoder)
  }

  public func createTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/canvases/create",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func duplicateTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasDuplicateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/canvases/duplicate",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func renameTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasRenameRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/canvases/rename",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func activateTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasActivateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/canvases/active",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func deleteTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/canvases/delete",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func setTaskBoardPolicyCanvasGlobalEnforcement(
    request: TaskBoardPolicyCanvasSetGlobalEnforcementRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/canvases/global-enforcement",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func createTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/scenarios/create",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func updateTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioUpdateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/scenarios/update",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func deleteTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/scenarios/delete",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func resetTaskBoardPolicyScenarios(
    request: TaskBoardPolicyScenarioResetRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/scenarios/reset",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func taskBoardPolicyPipeline(
    canvasId: String? = nil
  ) async throws -> TaskBoardPolicyPipelineDocument {
    try await get(
      "/v1/task-board/policy/pipeline",
      queryItems: taskBoardPolicyCanvasQueryItems(canvasId: canvasId),
      decoder: PolicyWireCoding.decoder
    )
  }

  public func saveTaskBoardPolicyPipelineDraft(
    request: TaskBoardPolicyPipelineSaveDraftRequest
  ) async throws -> TaskBoardPolicyPipelineSaveDraftResponse {
    try await put(
      "/v1/task-board/policy/pipeline",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func simulateTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineSimulateRequest
  ) async throws -> TaskBoardPolicyPipelineSimulationResult {
    let wire: PolicyPipelineSimulationResultWire = try await post(
      "/v1/task-board/policy/simulate",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardPolicyPipelineSimulationResult(wire: wire)
  }

  public func promoteTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelinePromoteRequest
  ) async throws -> TaskBoardPolicyPipelinePromoteResponse {
    try await post(
      "/v1/task-board/policy/promote",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func makeLiveTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineMakeLiveRequest
  ) async throws -> TaskBoardPolicyPipelineMakeLiveResponse {
    try await post(
      "/v1/task-board/policy/make-live",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func goLiveDiffTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineGoLiveDiffRequest
  ) async throws -> TaskBoardPolicyPipelineGoLiveDiff {
    try await post(
      "/v1/task-board/policy/go-live-diff",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func replayTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineReplayRequest
  ) async throws -> TaskBoardPolicyPipelineReplayResult {
    try await post(
      "/v1/task-board/policy/replay",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func taskBoardPolicyPipelineAudit(
    canvasId: String? = nil
  ) async throws -> TaskBoardPolicyPipelineAuditSummary {
    let wire: PolicyPipelineAuditSummaryWire = try await get(
      "/v1/task-board/policy/audit",
      queryItems: taskBoardPolicyCanvasQueryItems(canvasId: canvasId),
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardPolicyPipelineAuditSummary(wire: wire)
  }

  public func exportTaskBoardPolicy(
    request: TaskBoardPolicyExportRequest
  ) async throws -> TaskBoardPolicyExportResponse {
    try await post(
      "/v1/task-board/policy/export",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func importTaskBoardPolicy(
    request: TaskBoardPolicyImportRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post(
      "/v1/task-board/policy/import",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  func taskBoardPolicyCanvasQueryItems(canvasId: String?) -> [URLQueryItem] {
    guard let canvasId else {
      return []
    }
    return [URLQueryItem(name: "canvas_id", value: canvasId)]
  }
}
