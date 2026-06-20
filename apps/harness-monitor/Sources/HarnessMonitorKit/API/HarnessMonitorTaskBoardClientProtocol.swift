import Foundation

public protocol HarnessMonitorTaskBoardClientProtocol: Sendable {
  func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem]
  func taskBoardItem(id: String) async throws -> TaskBoardItem
  func createTaskBoardItem(request: TaskBoardCreateItemRequest) async throws -> TaskBoardItem
  func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem
  func deleteTaskBoardItem(id: String) async throws -> TaskBoardItem
  func beginTaskBoardPlan(id: String) async throws -> TaskBoardPlanningResponse
  func submitTaskBoardPlan(
    id: String,
    request: TaskBoardPlanSubmitRequest
  ) async throws -> TaskBoardPlanningResponse
  func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> TaskBoardPlanningResponse
  func revokeTaskBoardPlan(
    id: String,
    request: TaskBoardPlanRevokeRequest
  ) async throws -> TaskBoardPlanningResponse
  func syncTaskBoard(request: TaskBoardSyncRequest) async throws -> TaskBoardSyncSummary
  func dispatchTaskBoard(request: TaskBoardDispatchRequest) async throws -> TaskBoardDispatchSummary
  func evaluateTaskBoard(request: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
  func auditTaskBoard(status: TaskBoardStatus?) async throws -> TaskBoardAuditSummary
  func taskBoardProjects(status: TaskBoardStatus?) async throws -> [TaskBoardProjectSummary]
  func taskBoardMachines(status: TaskBoardStatus?) async throws -> [TaskBoardMachineSummary]
  func taskBoardHostLocal() async throws -> TaskBoardHostMachine
  func taskBoardHostList() async throws -> [TaskBoardHostMachine]
  func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) async throws -> TaskBoardHostMachine
  func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus
  func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus
  func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus
  func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest
  ) async throws -> TaskBoardOrchestratorRunOnceResponse
  func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings
  func updateTaskBoardOrchestratorSettings(
    request: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings
  func taskBoardGitRuntimeConfig() async throws -> TaskBoardGitRuntimeConfig
  func updateTaskBoardGitRuntimeConfig(
    request: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig
  func syncTaskBoardGitHubTokens(
    request: TaskBoardGitHubTokensSyncRequest
  ) async throws -> TaskBoardGitHubTokensSyncResponse
  func syncTaskBoardTodoistToken(
    request: TaskBoardTodoistTokenSyncRequest
  ) async throws -> TaskBoardTodoistTokenSyncResponse
  func syncTaskBoardOpenRouterToken(
    request: TaskBoardOpenRouterTokenSyncRequest
  ) async throws -> TaskBoardOpenRouterTokenSyncResponse
  func taskBoardGitIdentityDefaults() async throws -> TaskBoardGitIdentityDefaults
  func verifyTaskBoardGitSigning(
    request: TaskBoardGitSigningVerifyRequest
  ) async throws -> TaskBoardGitSigningVerifyResponse
  func drainTaskBoardGitRuntimeSecrets() async throws -> TaskBoardGitRuntimeDrainSecretsResponse
  func taskBoardPolicyCanvasWorkspace() async throws -> TaskBoardPolicyCanvasWorkspace
  func createTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
  func duplicateTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasDuplicateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
  func renameTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasRenameRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
  func activateTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasActivateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
  func deleteTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
  func setTaskBoardPolicyCanvasGlobalEnforcement(
    request: TaskBoardPolicyCanvasSetGlobalEnforcementRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
  func createTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
  func updateTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioUpdateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
  func deleteTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
  func resetTaskBoardPolicyScenarios(
    request: TaskBoardPolicyScenarioResetRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
  func taskBoardPolicyPipeline(canvasId: String?) async throws -> TaskBoardPolicyPipelineDocument
  func saveTaskBoardPolicyPipelineDraft(
    request: TaskBoardPolicyPipelineSaveDraftRequest
  ) async throws -> TaskBoardPolicyPipelineSaveDraftResponse
  func simulateTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineSimulateRequest
  ) async throws -> TaskBoardPolicyPipelineSimulationResult
  func promoteTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelinePromoteRequest
  ) async throws -> TaskBoardPolicyPipelinePromoteResponse
  func makeLiveTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineMakeLiveRequest
  ) async throws -> TaskBoardPolicyPipelineMakeLiveResponse
  func goLiveDiffTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineGoLiveDiffRequest
  ) async throws -> TaskBoardPolicyPipelineGoLiveDiff
  func taskBoardPolicyPipelineAudit(canvasId: String?) async throws
    -> TaskBoardPolicyPipelineAuditSummary
  func exportTaskBoardPolicy(
    request: TaskBoardPolicyExportRequest
  ) async throws -> TaskBoardPolicyExportResponse
  func importTaskBoardPolicy(
    request: TaskBoardPolicyImportRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace
}

extension HarnessMonitorTaskBoardClientProtocol {
  public func taskBoardItems(status _: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func taskBoardItem(id _: String) async throws -> TaskBoardItem {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func createTaskBoardItem(
    request _: TaskBoardCreateItemRequest
  ) async throws -> TaskBoardItem {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func updateTaskBoardItem(
    id _: String,
    request _: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func deleteTaskBoardItem(id _: String) async throws -> TaskBoardItem {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func beginTaskBoardPlan(id _: String) async throws -> TaskBoardPlanningResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board planning unavailable")
  }

  public func submitTaskBoardPlan(
    id _: String,
    request _: TaskBoardPlanSubmitRequest
  ) async throws -> TaskBoardPlanningResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board planning unavailable")
  }

  public func approveTaskBoardPlan(
    id _: String,
    request _: TaskBoardPlanApproveRequest
  ) async throws -> TaskBoardPlanningResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board planning unavailable")
  }

  public func revokeTaskBoardPlan(
    id _: String,
    request _: TaskBoardPlanRevokeRequest
  ) async throws -> TaskBoardPlanningResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board planning unavailable")
  }

  public func syncTaskBoard(request _: TaskBoardSyncRequest) async throws -> TaskBoardSyncSummary {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func syncTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardSyncSummary {
    try await syncTaskBoard(request: TaskBoardSyncRequest(status: status))
  }

  public func dispatchTaskBoard(request _: TaskBoardDispatchRequest) async throws
    -> TaskBoardDispatchSummary
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func evaluateTaskBoard(request _: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func dispatchTaskBoard(
    status: TaskBoardStatus? = nil,
    itemId: String? = nil,
    dryRun: Bool = true,
    projectDir: String? = nil
  ) async throws -> TaskBoardDispatchSummary {
    try await dispatchTaskBoard(
      request: TaskBoardDispatchRequest(
        status: status,
        itemId: itemId,
        dryRun: dryRun,
        projectDir: projectDir
      )
    )
  }

  public func evaluateTaskBoard(
    status: TaskBoardStatus? = nil,
    itemId: String? = nil,
    dryRun: Bool = false
  ) async throws -> TaskBoardEvaluationSummary {
    try await evaluateTaskBoard(
      request: TaskBoardEvaluateRequest(status: status, itemId: itemId, dryRun: dryRun)
    )
  }

  public func auditTaskBoard(status _: TaskBoardStatus?) async throws -> TaskBoardAuditSummary {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func taskBoardProjects(status _: TaskBoardStatus?) async throws
    -> [TaskBoardProjectSummary]
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func taskBoardMachines(status _: TaskBoardStatus?) async throws
    -> [TaskBoardMachineSummary]
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func taskBoardHostLocal() async throws -> TaskBoardHostMachine {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board host unavailable")
  }

  public func taskBoardHostList() async throws -> [TaskBoardHostMachine] {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board host unavailable")
  }

  public func setTaskBoardHostProjectTypes(
    request _: TaskBoardHostSetProjectTypesRequest
  ) async throws -> TaskBoardHostMachine {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board host unavailable")
  }

  public func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func runTaskBoardOrchestratorOnce(
    request _: TaskBoardOrchestratorRunOnceRequest
  ) async throws -> TaskBoardOrchestratorRunOnceResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func updateTaskBoardOrchestratorSettings(
    request _: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func taskBoardGitRuntimeConfig() async throws -> TaskBoardGitRuntimeConfig {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func updateTaskBoardGitRuntimeConfig(
    request _: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func syncTaskBoardGitHubTokens(
    request _: TaskBoardGitHubTokensSyncRequest
  ) async throws -> TaskBoardGitHubTokensSyncResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func syncTaskBoardTodoistToken(
    request _: TaskBoardTodoistTokenSyncRequest
  ) async throws -> TaskBoardTodoistTokenSyncResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func syncTaskBoardOpenRouterToken(
    request _: TaskBoardOpenRouterTokenSyncRequest
  ) async throws -> TaskBoardOpenRouterTokenSyncResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func taskBoardGitIdentityDefaults() async throws -> TaskBoardGitIdentityDefaults {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func verifyTaskBoardGitSigning(
    request _: TaskBoardGitSigningVerifyRequest
  ) async throws -> TaskBoardGitSigningVerifyResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func drainTaskBoardGitRuntimeSecrets() async throws
    -> TaskBoardGitRuntimeDrainSecretsResponse
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func taskBoardPolicyCanvasWorkspace() async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func createTaskBoardPolicyCanvas(
    request _: TaskBoardPolicyCanvasCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func duplicateTaskBoardPolicyCanvas(
    request _: TaskBoardPolicyCanvasDuplicateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func renameTaskBoardPolicyCanvas(
    request _: TaskBoardPolicyCanvasRenameRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func activateTaskBoardPolicyCanvas(
    request _: TaskBoardPolicyCanvasActivateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func deleteTaskBoardPolicyCanvas(
    request _: TaskBoardPolicyCanvasDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func setTaskBoardPolicyCanvasGlobalEnforcement(
    request _: TaskBoardPolicyCanvasSetGlobalEnforcementRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board policy unavailable")
  }

  public func runTaskBoardOrchestratorOnce() async throws -> TaskBoardOrchestratorRunOnceResponse {
    try await runTaskBoardOrchestratorOnce(request: TaskBoardOrchestratorRunOnceRequest())
  }
}
