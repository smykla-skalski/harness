import Foundation

public protocol HarnessMonitorTaskBoardClientProtocol: Sendable {
  func taskBoardCapabilities() async throws -> TaskBoardCapabilities
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
  func pickTaskBoardDispatch(
    request: TaskBoardDispatchPickRequest
  ) async throws -> TaskBoardDispatchPickResult
  func deliverTaskBoardDispatch(
    request: TaskBoardDispatchDeliverRequest
  ) async throws -> TaskBoardDispatchDelivery
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
  func syncTaskBoardGitRuntimeKeyMaterial(
    request: TaskBoardGitRuntimeKeyMaterialSyncRequest
  ) async throws -> TaskBoardGitRuntimeKeyMaterialSyncResponse
  func prepareTaskBoardGitRuntimeSecretHandoff() async throws
    -> TaskBoardGitRuntimeSecretHandoffPrepareResponse
  func acknowledgeTaskBoardGitRuntimeSecretHandoff(
    request: TaskBoardGitRuntimeSecretHandoffAckRequest
  ) async throws -> TaskBoardGitRuntimeSecretHandoffAckResponse
  func policyCanvasWorkspace() async throws -> PolicyCanvasWorkspace
  func createPolicyCanvas(
    request: PolicyCanvasCreateRequest
  ) async throws -> PolicyCanvasWorkspace
  func duplicatePolicyCanvas(
    request: PolicyCanvasDuplicateRequest
  ) async throws -> PolicyCanvasWorkspace
  func renamePolicyCanvas(
    request: PolicyCanvasRenameRequest
  ) async throws -> PolicyCanvasWorkspace
  func activatePolicyCanvas(
    request: PolicyCanvasActivateRequest
  ) async throws -> PolicyCanvasWorkspace
  func deletePolicyCanvas(
    request: PolicyCanvasDeleteRequest
  ) async throws -> PolicyCanvasWorkspace
  func setPolicyCanvasGlobalEnforcement(
    request: PolicyCanvasSetGlobalEnforcementRequest
  ) async throws -> PolicyCanvasWorkspace
  func setPolicyCanvasSpawnRequiresLivePolicy(
    request: PolicyCanvasSetSpawnRequiresLivePolicyRequest
  ) async throws -> PolicyCanvasWorkspace
  func setPolicyCanvasSpawnKillSwitch(
    request: PolicyCanvasSetSpawnKillSwitchRequest
  ) async throws -> PolicyCanvasWorkspace
  func policyApprovalGrants() async throws -> [PolicyApprovalGrant]
  func resolvePolicyApprovalGrant(
    request: PolicyApprovalGrantResolveRequest
  ) async throws -> PolicyApprovalGrant
  func revokePolicyApprovalGrant(
    request: PolicyApprovalGrantRevokeRequest
  ) async throws -> PolicyApprovalGrant
  func createPolicyScenario(
    request: PolicyScenarioCreateRequest
  ) async throws -> PolicyCanvasWorkspace
  func updatePolicyScenario(
    request: PolicyScenarioUpdateRequest
  ) async throws -> PolicyCanvasWorkspace
  func deletePolicyScenario(
    request: PolicyScenarioDeleteRequest
  ) async throws -> PolicyCanvasWorkspace
  func resetPolicyScenarios(
    request: PolicyScenarioResetRequest
  ) async throws -> PolicyCanvasWorkspace
  func policyPipeline(canvasId: String?) async throws -> PolicyPipelineDocument
  func savePolicyPipelineDraft(
    request: PolicyPipelineSaveDraftRequest
  ) async throws -> PolicyPipelineSaveDraftResponse
  func simulatePolicyPipeline(
    request: PolicyPipelineSimulateRequest
  ) async throws -> PolicyPipelineSimulationResult
  func promotePolicyPipeline(
    request: PolicyPipelinePromoteRequest
  ) async throws -> PolicyPipelinePromoteResponse
  func makeLivePolicyPipeline(
    request: PolicyPipelineMakeLiveRequest
  ) async throws -> PolicyPipelineMakeLiveResponse
  func goLiveDiffPolicyPipeline(
    request: PolicyPipelineGoLiveDiffRequest
  ) async throws -> PolicyPipelineGoLiveDiff
  func replayPolicyPipeline(
    request: PolicyPipelineReplayRequest
  ) async throws -> PolicyPipelineReplayResult
  func policyPipelineAudit(canvasId: String?) async throws
    -> PolicyPipelineAuditSummary
  func exportPolicyCanvas(
    request: PolicyCanvasExportRequest
  ) async throws -> PolicyCanvasExportResponse
  func importPolicyCanvas(
    request: PolicyCanvasImportRequest
  ) async throws -> PolicyCanvasWorkspace
}

extension HarnessMonitorTaskBoardClientProtocol {
  public func taskBoardCapabilities() async throws -> TaskBoardCapabilities {
    throw HarnessMonitorAPIError.server(
      code: 501,
      message: "Database-backed task board unavailable"
    )
  }

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

  public func syncTaskBoardGitRuntimeKeyMaterial(
    request _: TaskBoardGitRuntimeKeyMaterialSyncRequest
  ) async throws -> TaskBoardGitRuntimeKeyMaterialSyncResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func prepareTaskBoardGitRuntimeSecretHandoff() async throws
    -> TaskBoardGitRuntimeSecretHandoffPrepareResponse
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func acknowledgeTaskBoardGitRuntimeSecretHandoff(
    request _: TaskBoardGitRuntimeSecretHandoffAckRequest
  ) async throws -> TaskBoardGitRuntimeSecretHandoffAckResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board unavailable")
  }

  public func policyCanvasWorkspace() async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func createPolicyCanvas(
    request _: PolicyCanvasCreateRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func duplicatePolicyCanvas(
    request _: PolicyCanvasDuplicateRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func renamePolicyCanvas(
    request _: PolicyCanvasRenameRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func activatePolicyCanvas(
    request _: PolicyCanvasActivateRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func deletePolicyCanvas(
    request _: PolicyCanvasDeleteRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func setPolicyCanvasGlobalEnforcement(
    request _: PolicyCanvasSetGlobalEnforcementRequest
  ) async throws -> PolicyCanvasWorkspace {
    throw HarnessMonitorAPIError.server(code: 501, message: "Policy canvas unavailable")
  }

  public func runTaskBoardOrchestratorOnce() async throws -> TaskBoardOrchestratorRunOnceResponse {
    try await runTaskBoardOrchestratorOnce(request: TaskBoardOrchestratorRunOnceRequest())
  }
}
