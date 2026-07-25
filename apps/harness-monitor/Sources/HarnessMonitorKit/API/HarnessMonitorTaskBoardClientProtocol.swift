import Foundation

public protocol HarnessMonitorTaskBoardClientProtocol: Sendable {
  func taskBoardCapabilities() async throws -> TaskBoardCapabilities
  func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem]
  func taskBoardItemsSnapshot(status: TaskBoardStatus?) async throws -> TaskBoardListItemsSnapshot
  func taskBoardItem(id: String) async throws -> TaskBoardItem
  func taskBoardItemPositionSnapshot(id: String) async throws -> TaskBoardItemPositionSnapshot
  func setTaskBoardItemPosition(id: String, request: TaskBoardSetItemPositionRequest) async throws
    -> TaskBoardItemPositionMutationResponse
  func resetTaskBoardItemPosition(id: String, request: TaskBoardResetItemPositionRequest)
    async throws -> TaskBoardItemPositionMutationResponse
  func taskBoardItemTriageCurrent(id: String) async throws -> TaskBoardTriageCurrentResponse
  func taskBoardItemTriageHistory(
    id: String,
    beforeGeneration: UInt64?,
    limit: UInt32?
  ) async throws -> TaskBoardTriageHistoryResponse
  func setTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardSetTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse
  func clearTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardClearTriageOverrideRequest
  ) async throws -> TaskBoardTriageOverrideMutationResponse
  func taskBoardTriageRulesDraft() async throws -> TaskBoardTriageRulesDraftResponse
  func saveTaskBoardTriageRulesDraft(
    request: TaskBoardSaveTriageRulesDraftRequest
  ) async throws -> TriageRuleSetDraftSaveResult
  func previewTaskBoardTriageRules(
    request: TaskBoardPreviewTriageRulesRequest
  ) async throws -> TriageRuleSetPreviewResult
  func activateTaskBoardTriageRules(
    request: TaskBoardActivateTriageRulesRequest
  ) async throws -> TriageRuleSetActivationResult
  func taskBoardTriageRulesRevisions(limit: UInt32?) async throws
    -> TaskBoardTriageRulesRevisionsResponse
  func taskBoardTriageRulesAudit(limit: UInt32?) async throws -> TaskBoardTriageRulesAuditResponse
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
  func updateTaskBoardProject(
    request: TaskBoardProjectUpdateRequest
  ) async throws -> TaskBoardProject
  func taskBoardMachines(status: TaskBoardStatus?) async throws -> [TaskBoardMachineSummary]
  func taskBoardHostLocal() async throws -> TaskBoardHostMachine
  func taskBoardHostList() async throws -> [TaskBoardHostMachine]
  func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) async throws -> TaskBoardHostMachine
  func taskBoardWorkingCopies() async throws -> [WorkingCopyListEntry]
  func obtainTaskBoardWorkingCopy(
    repository: String,
    allowClone: Bool
  ) async throws -> WorkingCopyListEntry?
  func deleteTaskBoardWorkingCopy(repoKeySegment: String) async throws
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
  func taskBoardAutomationRuns(
    request: TaskBoardAutomationHistoryRequest
  ) async throws -> TaskBoardAutomationHistoryResponse
  func taskBoardAutomationRunDetail(runID: String) async throws -> TaskBoardAutomationRunDetail
  func taskBoardAutomationMetrics() async throws -> TaskBoardAutomationMetrics
  func forceCancelTaskBoardAutomation(
    request: TaskBoardAutomationForceCancelRequest
  ) async throws -> TaskBoardAutomationForceCancelResponse
  func taskBoardGitRuntimeConfig() async throws -> TaskBoardGitRuntimeConfig
  func updateTaskBoardGitRuntimeConfig(
    request: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig
  func syncTaskBoardGitHubTokens(
    request: TaskBoardGitHubTokensSyncRequest
  ) async throws -> TaskBoardGitHubTokensSyncResponse
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
