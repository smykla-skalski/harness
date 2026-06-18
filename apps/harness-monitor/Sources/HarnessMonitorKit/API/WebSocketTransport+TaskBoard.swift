import Foundation

extension WebSocketTransport {
  public func taskBoardItems(status: TaskBoardStatus? = nil) async throws -> [TaskBoardItem] {
    let params = try encodeParams(TaskBoardListItemsRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardList, params: params)
    let response: TaskBoardListItemsResponseWire = try decodePolicyWire(value)
    return response.items.map(TaskBoardItem.init(wire:))
  }

  public func taskBoardItem(id: String) async throws -> TaskBoardItem {
    let value = try await rpc(
      method: .taskBoardGet,
      params: .object(["id": .string(id)])
    )
    let wire: TaskBoardItemWire = try decodePolicyWire(value)
    return TaskBoardItem(wire: wire)
  }

  public func createTaskBoardItem(
    request: TaskBoardCreateItemRequest
  ) async throws -> TaskBoardItem {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardCreate, params: params)
    let wire: TaskBoardItemWire = try decodePolicyWire(value)
    return TaskBoardItem(wire: wire)
  }

  public func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardUpdate, params: params)
    let wire: TaskBoardItemWire = try decodePolicyWire(value)
    return TaskBoardItem(wire: wire)
  }

  public func deleteTaskBoardItem(id: String) async throws -> TaskBoardItem {
    let value = try await rpc(
      method: .taskBoardDelete,
      params: .object(["id": .string(id)])
    )
    let wire: TaskBoardItemWire = try decodePolicyWire(value)
    return TaskBoardItem(wire: wire)
  }

  public func beginTaskBoardPlan(id: String) async throws -> TaskBoardPlanningResponse {
    let value = try await rpc(
      method: .taskBoardPlanBegin,
      params: .object(["id": .string(id)])
    )
    let wire: TaskBoardPlanningResponseWire = try decodePolicyWire(value)
    return TaskBoardPlanningResponse(wire: wire)
  }

  public func submitTaskBoardPlan(
    id: String,
    request: TaskBoardPlanSubmitRequest
  ) async throws -> TaskBoardPlanningResponse {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardPlanSubmit, params: params)
    let wire: TaskBoardPlanningResponseWire = try decodePolicyWire(value)
    return TaskBoardPlanningResponse(wire: wire)
  }

  public func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> TaskBoardPlanningResponse {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardPlanApprove, params: params)
    let wire: TaskBoardPlanningResponseWire = try decodePolicyWire(value)
    return TaskBoardPlanningResponse(wire: wire)
  }

  public func revokeTaskBoardPlan(
    id: String,
    request: TaskBoardPlanRevokeRequest
  ) async throws -> TaskBoardPlanningResponse {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardPlanRevoke, params: params)
    let wire: TaskBoardPlanningResponseWire = try decodePolicyWire(value)
    return TaskBoardPlanningResponse(wire: wire)
  }

  public func syncTaskBoard(request: TaskBoardSyncRequest) async throws -> TaskBoardSyncSummary {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardSync, params: params)
    let wire: TaskBoardSyncSummaryWire = try decodePolicyWire(value)
    return TaskBoardSyncSummary(wire: wire)
  }

  public func syncTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardSyncSummary {
    try await syncTaskBoard(request: TaskBoardSyncRequest(status: status))
  }

  public func dispatchTaskBoard(request: TaskBoardDispatchRequest) async throws
    -> TaskBoardDispatchSummary
  {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardDispatch, params: params)
    let wire: DispatchExecutionSummaryWire = try decodePolicyWire(value)
    return TaskBoardDispatchSummary(wire: wire)
  }

  public func evaluateTaskBoard(request: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
  {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardEvaluate, params: params)
    let wire: TaskBoardEvaluationSummaryWire = try decodePolicyWire(value)
    return TaskBoardEvaluationSummary(wire: wire)
  }

  public func auditTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardAuditSummary {
    let params = try encodeParams(TaskBoardStatusFilterRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardAudit, params: params)
    let wire: TaskBoardAuditSummaryWire = try decodePolicyWire(value)
    return TaskBoardAuditSummary(wire: wire)
  }

  public func taskBoardProjects(status: TaskBoardStatus? = nil) async throws
    -> [TaskBoardProjectSummary]
  {
    let params = try encodeParams(TaskBoardStatusFilterRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardProjects, params: params)
    let wire: [TaskBoardProjectSummaryWire] = try decodePolicyWire(value)
    return wire.map(TaskBoardProjectSummary.init(wire:))
  }

  public func taskBoardMachines(status: TaskBoardStatus? = nil) async throws
    -> [TaskBoardMachineSummary]
  {
    let params = try encodeParams(TaskBoardStatusFilterRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardMachines, params: params)
    let wire: [TaskBoardMachineSummaryWire] = try decodePolicyWire(value)
    return wire.map(TaskBoardMachineSummary.init(wire:))
  }

  public func taskBoardHostLocal() async throws -> TaskBoardHostMachine {
    let value = try await rpc(method: .taskBoardHostLocal)
    let wire: MachineWire = try decodePolicyWire(value)
    return TaskBoardHostMachine(wire: wire)
  }

  public func taskBoardHostList() async throws -> [TaskBoardHostMachine] {
    let value = try await rpc(method: .taskBoardHostList)
    let wire: [MachineWire] = try decodePolicyWire(value)
    return wire.map(TaskBoardHostMachine.init(wire:))
  }

  public func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) async throws -> TaskBoardHostMachine {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardHostSetProjectTypes, params: params)
    let wire: MachineWire = try decodePolicyWire(value)
    return TaskBoardHostMachine(wire: wire)
  }

  public func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    let value = try await rpc(method: .taskBoardOrchestratorStatus)
    let wire: TaskBoardOrchestratorStatusWire = try decodePolicyWire(value)
    return TaskBoardOrchestratorStatus(wire: wire)
  }

  public func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    let value = try await rpc(method: .taskBoardOrchestratorStart)
    let wire: TaskBoardOrchestratorStatusWire = try decodePolicyWire(value)
    return TaskBoardOrchestratorStatus(wire: wire)
  }

  public func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    let value = try await rpc(method: .taskBoardOrchestratorStop)
    let wire: TaskBoardOrchestratorStatusWire = try decodePolicyWire(value)
    return TaskBoardOrchestratorStatus(wire: wire)
  }

  public func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest = TaskBoardOrchestratorRunOnceRequest()
  ) async throws
    -> TaskBoardOrchestratorRunOnceResponse
  {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorRunOnce, params: params)
    let wire: TaskBoardOrchestratorStatusWire = try decodePolicyWire(value)
    return TaskBoardOrchestratorStatus(wire: wire)
  }

  public func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    let value = try await rpc(method: .taskBoardOrchestratorSettingsGet)
    let wire: TaskBoardOrchestratorSettingsWire = try decodePolicyWire(value)
    return TaskBoardOrchestratorSettings(wire: wire)
  }

  public func updateTaskBoardOrchestratorSettings(
    request: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorSettingsUpdate, params: params)
    let wire: TaskBoardOrchestratorSettingsWire = try decodePolicyWire(value)
    return TaskBoardOrchestratorSettings(wire: wire)
  }

  public func taskBoardGitRuntimeConfig() async throws -> TaskBoardGitRuntimeConfig {
    let value = try await rpc(method: .taskBoardOrchestratorRuntimeConfigGet)
    let wire: TaskBoardGitRuntimeConfigWire = try decodePolicyWire(value)
    return TaskBoardGitRuntimeConfig(wire: wire)
  }

  public func updateTaskBoardGitRuntimeConfig(
    request: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorRuntimeConfigUpdate, params: params)
    let wire: TaskBoardGitRuntimeConfigWire = try decodePolicyWire(value)
    return TaskBoardGitRuntimeConfig(wire: wire)
  }

  public func syncTaskBoardGitHubTokens(
    request: TaskBoardGitHubTokensSyncRequest
  ) async throws -> TaskBoardGitHubTokensSyncResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorGitHubTokensSync, params: params)
    let wire: TaskBoardGitHubTokensSyncResponseWire = try decodePolicyWire(value)
    return TaskBoardGitHubTokensSyncResponse(wire: wire)
  }

  public func syncTaskBoardOpenRouterToken(
    request: TaskBoardOpenRouterTokenSyncRequest
  ) async throws -> TaskBoardOpenRouterTokenSyncResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorOpenRouterTokenSync, params: params)
    let wire: TaskBoardOpenRouterTokenSyncResponseWire = try decodePolicyWire(value)
    return TaskBoardOpenRouterTokenSyncResponse(wire: wire)
  }

  public func syncTaskBoardTodoistToken(
    request: TaskBoardTodoistTokenSyncRequest
  ) async throws -> TaskBoardTodoistTokenSyncResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorTodoistTokenSync, params: params)
    let wire: TaskBoardTodoistTokenSyncResponseWire = try decodePolicyWire(value)
    return TaskBoardTodoistTokenSyncResponse(wire: wire)
  }

  public func taskBoardGitIdentityDefaults() async throws -> TaskBoardGitIdentityDefaults {
    let value = try await rpc(method: .taskBoardGitIdentityDefaults)
    return try decodePolicyWire(value)
  }

  public func verifyTaskBoardGitSigning(
    request: TaskBoardGitSigningVerifyRequest
  ) async throws -> TaskBoardGitSigningVerifyResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardGitSigningVerify, params: params)
    let wire: TaskBoardGitSigningVerifyResponseWire = try decodePolicyWire(value)
    return TaskBoardGitSigningVerifyResponse(wire: wire)
  }

  public func drainTaskBoardGitRuntimeSecrets() async throws
    -> TaskBoardGitRuntimeDrainSecretsResponse
  {
    let value = try await rpc(method: .taskBoardGitRuntimeDrainSecrets)
    let wire: TaskBoardGitRuntimeDrainSecretsResponseWire = try decodePolicyWire(value)
    return TaskBoardGitRuntimeDrainSecretsResponse(wire: wire)
  }

  public func taskBoardPolicyCanvasWorkspace() async throws -> TaskBoardPolicyCanvasWorkspace {
    let value = try await rpc(method: .taskBoardPolicyCanvasWorkspaceGet)
    return try decodePolicyWire(value)
  }

  public func createTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyCanvasCreate, params: params)
    return try decodePolicyWire(value)
  }

  public func duplicateTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasDuplicateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyCanvasDuplicate, params: params)
    return try decodePolicyWire(value)
  }

  public func renameTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasRenameRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyCanvasRename, params: params)
    return try decodePolicyWire(value)
  }

  public func activateTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasActivateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyCanvasSetActive, params: params)
    return try decodePolicyWire(value)
  }

  public func deleteTaskBoardPolicyCanvas(
    request: TaskBoardPolicyCanvasDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyCanvasDelete, params: params)
    return try decodePolicyWire(value)
  }

  public func setTaskBoardPolicyCanvasGlobalEnforcement(
    request: TaskBoardPolicyCanvasSetGlobalEnforcementRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyCanvasSetGlobalEnforcement, params: params)
    return try decodePolicyWire(value)
  }

  public func taskBoardPolicyPipeline(
    canvasId: String? = nil
  ) async throws -> TaskBoardPolicyPipelineDocument {
    let value = try await rpc(
      method: .taskBoardPolicyPipelineGet,
      params: taskBoardPolicyCanvasRPCParams(canvasId: canvasId)
    )
    return try decodePolicyWire(value)
  }

  public func saveTaskBoardPolicyPipelineDraft(
    request: TaskBoardPolicyPipelineSaveDraftRequest
  ) async throws -> TaskBoardPolicyPipelineSaveDraftResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyPipelineSaveDraft, params: params)
    return try decodePolicyWire(value)
  }

  public func simulateTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineSimulateRequest
  ) async throws -> TaskBoardPolicyPipelineSimulationResult {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyPipelineSimulate, params: params)
    let wire: PolicyPipelineSimulationResultWire = try decodePolicyWire(value)
    return TaskBoardPolicyPipelineSimulationResult(wire: wire)
  }

  public func promoteTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelinePromoteRequest
  ) async throws -> TaskBoardPolicyPipelinePromoteResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyPipelinePromote, params: params)
    return try decodePolicyWire(value)
  }

  public func taskBoardPolicyPipelineAudit(
    canvasId: String? = nil
  ) async throws -> TaskBoardPolicyPipelineAuditSummary {
    let value = try await rpc(
      method: .taskBoardPolicyPipelineAudit,
      params: taskBoardPolicyCanvasRPCParams(canvasId: canvasId)
    )
    let wire: PolicyPipelineAuditSummaryWire = try decodePolicyWire(value)
    return TaskBoardPolicyPipelineAuditSummary(wire: wire)
  }

  public func exportTaskBoardPolicy(
    request: TaskBoardPolicyExportRequest
  ) async throws -> TaskBoardPolicyExportResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyExport, params: params)
    return try decodePolicyWire(value)
  }

  public func importTaskBoardPolicy(
    request: TaskBoardPolicyImportRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyImport, params: params)
    return try decodePolicyWire(value)
  }

  private func taskBoardPolicyCanvasRPCParams(canvasId: String?) -> JSONValue? {
    guard let canvasId else {
      return nil
    }
    return .object(["canvas_id": .string(canvasId)])
  }
}
