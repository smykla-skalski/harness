import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardItems(status: TaskBoardStatus? = nil) async throws -> [TaskBoardItem] {
    let response: TaskBoardListItemsResponse = try await get(
      "/v1/task-board/items",
      queryItems: taskBoardQueryItems(status: status)
    )
    return response.items
  }

  public func taskBoardItem(id: String) async throws -> TaskBoardItem {
    try await get("/v1/task-board/items/\(id)")
  }

  public func createTaskBoardItem(
    request: TaskBoardCreateItemRequest
  ) async throws -> TaskBoardItem {
    try await post("/v1/task-board/items", body: request)
  }

  public func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    try await put("/v1/task-board/items/\(id)", body: request)
  }

  public func deleteTaskBoardItem(id: String) async throws -> TaskBoardItem {
    try await delete("/v1/task-board/items/\(id)")
  }

  public func beginTaskBoardPlan(id: String) async throws -> TaskBoardPlanningResponse {
    try await post("/v1/task-board/items/\(id)/planning/begin", body: EmptyBody())
  }

  public func submitTaskBoardPlan(
    id: String,
    request: TaskBoardPlanSubmitRequest
  ) async throws -> TaskBoardPlanningResponse {
    try await post("/v1/task-board/items/\(id)/planning/submit", body: request)
  }

  public func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> TaskBoardPlanningResponse {
    try await post("/v1/task-board/items/\(id)/planning/approve", body: request)
  }

  public func revokeTaskBoardPlan(
    id: String,
    request: TaskBoardPlanRevokeRequest = TaskBoardPlanRevokeRequest()
  ) async throws -> TaskBoardPlanningResponse {
    try await post("/v1/task-board/items/\(id)/planning/revoke", body: request)
  }

  public func syncTaskBoard(request: TaskBoardSyncRequest) async throws -> TaskBoardSyncSummary {
    try await post("/v1/task-board/sync", body: request)
  }

  public func syncTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardSyncSummary {
    try await syncTaskBoard(request: TaskBoardSyncRequest(status: status))
  }

  public func dispatchTaskBoard(request: TaskBoardDispatchRequest) async throws
    -> TaskBoardDispatchSummary
  {
    try await post("/v1/task-board/dispatch", body: request)
  }

  public func evaluateTaskBoard(request: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
  {
    try await post("/v1/task-board/evaluate", body: request)
  }

  public func auditTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardAuditSummary {
    try await get(
      "/v1/task-board/audit",
      queryItems: taskBoardQueryItems(status: status)
    )
  }

  public func taskBoardProjects(status: TaskBoardStatus? = nil) async throws
    -> [TaskBoardProjectSummary]
  {
    try await get(
      "/v1/task-board/projects",
      queryItems: taskBoardQueryItems(status: status)
    )
  }

  public func taskBoardMachines(status: TaskBoardStatus? = nil) async throws
    -> [TaskBoardMachineSummary]
  {
    try await get(
      "/v1/task-board/machines",
      queryItems: taskBoardQueryItems(status: status)
    )
  }

  public func taskBoardHostLocal() async throws -> TaskBoardHostMachine {
    try await get("/v1/task-board/host/local")
  }

  public func taskBoardHostList() async throws -> [TaskBoardHostMachine] {
    try await get("/v1/task-board/host/list")
  }

  public func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) async throws -> TaskBoardHostMachine {
    try await put("/v1/task-board/host/project-types", body: request)
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
    try await put("/v1/task-board/orchestrator/github-tokens", body: request)
  }

  public func syncTaskBoardTodoistToken(
    request: TaskBoardTodoistTokenSyncRequest
  ) async throws -> TaskBoardTodoistTokenSyncResponse {
    try await put("/v1/task-board/orchestrator/todoist-token", body: request)
  }

  public func syncTaskBoardOpenRouterToken(
    request: TaskBoardOpenRouterTokenSyncRequest
  ) async throws -> TaskBoardOpenRouterTokenSyncResponse {
    try await put("/v1/task-board/orchestrator/openrouter-token", body: request)
  }

  public func taskBoardGitIdentityDefaults() async throws -> TaskBoardGitIdentityDefaults {
    try await get("/v1/task-board/git/identity-defaults")
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
    try await get("/v1/task-board/policy/canvases")
  }

  public func createTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post("/v1/task-board/policy/canvases/create", body: request)
  }

  public func duplicateTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasDuplicateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post("/v1/task-board/policy/canvases/duplicate", body: request)
  }

  public func renameTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasRenameRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post("/v1/task-board/policy/canvases/rename", body: request)
  }

  public func activateTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasActivateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post("/v1/task-board/policy/canvases/active", body: request)
  }

  public func deleteTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    try await post("/v1/task-board/policy/canvases/delete", body: request)
  }

  public func taskBoardPolicyPipeline(
    canvasId: String? = nil
  ) async throws -> TaskBoardPolicyPipelineDocument {
    try await get(
      "/v1/task-board/policy/pipeline",
      queryItems: taskBoardPolicyCanvasQueryItems(canvasId: canvasId)
    )
  }

  public func saveTaskBoardPolicyPipelineDraft(
    request: TaskBoardPolicyPipelineSaveDraftRequest
  ) async throws -> TaskBoardPolicyPipelineSaveDraftResponse {
    try await put("/v1/task-board/policy/pipeline", body: request)
  }

  public func simulateTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineSimulateRequest
  ) async throws -> TaskBoardPolicyPipelineSimulationResult {
    try await post("/v1/task-board/policy/simulate", body: request)
  }

  public func promoteTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelinePromoteRequest
  ) async throws -> TaskBoardPolicyPipelinePromoteResponse {
    try await post("/v1/task-board/policy/promote", body: request)
  }

  public func taskBoardPolicyPipelineAudit(
    canvasId: String? = nil
  ) async throws -> TaskBoardPolicyPipelineAuditSummary {
    try await get(
      "/v1/task-board/policy/audit",
      queryItems: taskBoardPolicyCanvasQueryItems(canvasId: canvasId)
    )
  }

  private func taskBoardQueryItems(status: TaskBoardStatus?) -> [URLQueryItem] {
    guard let status else {
      return []
    }
    return [URLQueryItem(name: "status", value: status.rawValue)]
  }

  private func taskBoardPolicyCanvasQueryItems(canvasId: String?) -> [URLQueryItem] {
    guard let canvasId else {
      return []
    }
    return [URLQueryItem(name: "canvas_id", value: canvasId)]
  }
}
