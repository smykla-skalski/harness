import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardItems(status: TaskBoardStatus? = nil) async throws -> [TaskBoardItem] {
    let response: TaskBoardListItemsResponseWire = try await get(
      "/v1/task-board/items",
      queryItems: taskBoardQueryItems(status: status),
      decoder: PolicyWireCoding.decoder
    )
    return response.items.map(TaskBoardItem.init(wire:))
  }

  public func taskBoardItem(id: String) async throws -> TaskBoardItem {
    let wire: TaskBoardItemWire = try await get(
      "/v1/task-board/items/\(id)", decoder: PolicyWireCoding.decoder
    )
    return TaskBoardItem(wire: wire)
  }

  public func createTaskBoardItem(
    request: TaskBoardCreateItemRequest
  ) async throws -> TaskBoardItem {
    let wire: TaskBoardItemWire = try await post(
      "/v1/task-board/items", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardItem(wire: wire)
  }

  public func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    let wire: TaskBoardItemWire = try await put(
      "/v1/task-board/items/\(id)", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardItem(wire: wire)
  }

  public func deleteTaskBoardItem(id: String) async throws -> TaskBoardItem {
    let wire: TaskBoardItemWire = try await delete(
      "/v1/task-board/items/\(id)", decoder: PolicyWireCoding.decoder
    )
    return TaskBoardItem(wire: wire)
  }

  public func beginTaskBoardPlan(id: String) async throws -> TaskBoardPlanningResponse {
    let wire: TaskBoardPlanningResponseWire = try await post(
      "/v1/task-board/items/\(id)/planning/begin",
      body: EmptyBody(),
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardPlanningResponse(wire: wire)
  }

  public func submitTaskBoardPlan(
    id: String,
    request: TaskBoardPlanSubmitRequest
  ) async throws -> TaskBoardPlanningResponse {
    let wire: TaskBoardPlanningResponseWire = try await post(
      "/v1/task-board/items/\(id)/planning/submit",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardPlanningResponse(wire: wire)
  }

  public func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> TaskBoardPlanningResponse {
    let wire: TaskBoardPlanningResponseWire = try await post(
      "/v1/task-board/items/\(id)/planning/approve",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardPlanningResponse(wire: wire)
  }

  public func revokeTaskBoardPlan(
    id: String,
    request: TaskBoardPlanRevokeRequest = TaskBoardPlanRevokeRequest()
  ) async throws -> TaskBoardPlanningResponse {
    let wire: TaskBoardPlanningResponseWire = try await post(
      "/v1/task-board/items/\(id)/planning/revoke",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardPlanningResponse(wire: wire)
  }

  public func syncTaskBoard(request: TaskBoardSyncRequest) async throws -> TaskBoardSyncSummary {
    let wire: TaskBoardSyncSummaryWire = try await post(
      "/v1/task-board/sync", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardSyncSummary(wire: wire)
  }

  public func syncTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardSyncSummary {
    try await syncTaskBoard(request: TaskBoardSyncRequest(status: status))
  }

  public func dispatchTaskBoard(request: TaskBoardDispatchRequest) async throws
    -> TaskBoardDispatchSummary
  {
    let wire: DispatchExecutionSummaryWire = try await post(
      "/v1/task-board/dispatch", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardDispatchSummary(wire: wire)
  }

  public func evaluateTaskBoard(request: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
  {
    let wire: TaskBoardEvaluationSummaryWire = try await post(
      "/v1/task-board/evaluate", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardEvaluationSummary(wire: wire)
  }

  public func auditTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardAuditSummary {
    let wire: TaskBoardAuditSummaryWire = try await get(
      "/v1/task-board/audit",
      queryItems: taskBoardQueryItems(status: status),
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardAuditSummary(wire: wire)
  }

  public func taskBoardProjects(status: TaskBoardStatus? = nil) async throws
    -> [TaskBoardProjectSummary]
  {
    let wire: [TaskBoardProjectSummaryWire] = try await get(
      "/v1/task-board/projects",
      queryItems: taskBoardQueryItems(status: status),
      decoder: PolicyWireCoding.decoder
    )
    return wire.map(TaskBoardProjectSummary.init(wire:))
  }

  public func taskBoardMachines(status: TaskBoardStatus? = nil) async throws
    -> [TaskBoardMachineSummary]
  {
    let wire: [TaskBoardMachineSummaryWire] = try await get(
      "/v1/task-board/machines",
      queryItems: taskBoardQueryItems(status: status),
      decoder: PolicyWireCoding.decoder
    )
    return wire.map(TaskBoardMachineSummary.init(wire:))
  }

  public func taskBoardHostLocal() async throws -> TaskBoardHostMachine {
    let wire: MachineWire = try await get(
      "/v1/task-board/host/local", decoder: PolicyWireCoding.decoder
    )
    return TaskBoardHostMachine(wire: wire)
  }

  public func taskBoardHostList() async throws -> [TaskBoardHostMachine] {
    let wire: [MachineWire] = try await get(
      "/v1/task-board/host/list", decoder: PolicyWireCoding.decoder
    )
    return wire.map(TaskBoardHostMachine.init(wire:))
  }

  public func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) async throws -> TaskBoardHostMachine {
    let wire: MachineWire = try await put(
      "/v1/task-board/host/project-types", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardHostMachine(wire: wire)
  }

  public func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    try await get("/v1/task-board/orchestrator/status")
  }

  public func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    try await post("/v1/task-board/orchestrator/start", body: EmptyBody())
  }

  public func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    try await post("/v1/task-board/orchestrator/stop", body: EmptyBody())
  }

  public func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest = TaskBoardOrchestratorRunOnceRequest()
  ) async throws
    -> TaskBoardOrchestratorRunOnceResponse
  {
    try await post("/v1/task-board/orchestrator/run-once", body: request)
  }

  public func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    try await get("/v1/task-board/orchestrator/settings")
  }

  public func updateTaskBoardOrchestratorSettings(
    request: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    try await put("/v1/task-board/orchestrator/settings", body: request)
  }

  public func taskBoardGitRuntimeConfig() async throws -> TaskBoardGitRuntimeConfig {
    try await get("/v1/task-board/orchestrator/runtime-config")
  }

  public func updateTaskBoardGitRuntimeConfig(
    request: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig {
    try await put("/v1/task-board/orchestrator/runtime-config", body: request)
  }

  public func syncTaskBoardGitHubTokens(
    request: TaskBoardGitHubTokensSyncRequest
  ) async throws -> TaskBoardGitHubTokensSyncResponse {
    let wire: TaskBoardGitHubTokensSyncResponseWire = try await put(
      "/v1/task-board/orchestrator/github-tokens", body: request,
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardGitHubTokensSyncResponse(wire: wire)
  }

  public func syncTaskBoardTodoistToken(
    request: TaskBoardTodoistTokenSyncRequest
  ) async throws -> TaskBoardTodoistTokenSyncResponse {
    let wire: TaskBoardTodoistTokenSyncResponseWire = try await put(
      "/v1/task-board/orchestrator/todoist-token", body: request,
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardTodoistTokenSyncResponse(wire: wire)
  }

  public func syncTaskBoardOpenRouterToken(
    request: TaskBoardOpenRouterTokenSyncRequest
  ) async throws -> TaskBoardOpenRouterTokenSyncResponse {
    let wire: TaskBoardOpenRouterTokenSyncResponseWire = try await put(
      "/v1/task-board/orchestrator/openrouter-token", body: request,
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardOpenRouterTokenSyncResponse(wire: wire)
  }

  public func taskBoardGitIdentityDefaults() async throws -> TaskBoardGitIdentityDefaults {
    try await get("/v1/task-board/git/identity-defaults", decoder: PolicyWireCoding.decoder)
  }

  public func verifyTaskBoardGitSigning(
    request: TaskBoardGitSigningVerifyRequest
  ) async throws -> TaskBoardGitSigningVerifyResponse {
    try await post("/v1/task-board/git/signing/verify", body: request)
  }

  public func drainTaskBoardGitRuntimeSecrets() async throws
    -> TaskBoardGitRuntimeDrainSecretsResponse
  {
    try await post(
      "/v1/task-board/git/runtime/drain-secrets",
      body: TaskBoardGitRuntimeDrainSecretsRequest()
    )
  }

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

  private func taskBoardQueryItems(status: TaskBoardStatus?) -> [URLQueryItem] {
    guard let status else {
      return []
    }
    return [URLQueryItem(name: "status", value: status.rawValue)]
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

  private func taskBoardPolicyCanvasQueryItems(canvasId: String?) -> [URLQueryItem] {
    guard let canvasId else {
      return []
    }
    return [URLQueryItem(name: "canvas_id", value: canvasId)]
  }
}
