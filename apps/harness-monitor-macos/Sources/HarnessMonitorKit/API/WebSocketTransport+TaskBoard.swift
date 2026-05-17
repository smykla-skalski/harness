import Foundation

extension WebSocketTransport {
  public func taskBoardItems(status: TaskBoardStatus? = nil) async throws -> [TaskBoardItem] {
    let params = try encodeParams(TaskBoardListItemsRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardList, params: params)
    let response: TaskBoardListItemsResponse = try decode(value)
    return response.items
  }

  public func taskBoardItem(id: String) async throws -> TaskBoardItem {
    let value = try await rpc(
      method: .taskBoardGet,
      params: .object(["id": .string(id)])
    )
    return try decode(value)
  }

  public func createTaskBoardItem(
    request: TaskBoardCreateItemRequest
  ) async throws -> TaskBoardItem {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardCreate, params: params)
    return try decode(value)
  }

  public func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardUpdate, params: params)
    return try decode(value)
  }

  public func deleteTaskBoardItem(id: String) async throws -> TaskBoardItem {
    let value = try await rpc(
      method: .taskBoardDelete,
      params: .object(["id": .string(id)])
    )
    return try decode(value)
  }

  public func beginTaskBoardPlan(id: String) async throws -> TaskBoardPlanningResponse {
    let value = try await rpc(
      method: .taskBoardPlanBegin,
      params: .object(["id": .string(id)])
    )
    return try decode(value)
  }

  public func submitTaskBoardPlan(
    id: String,
    request: TaskBoardPlanSubmitRequest
  ) async throws -> TaskBoardPlanningResponse {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardPlanSubmit, params: params)
    return try decode(value)
  }

  public func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> TaskBoardPlanningResponse {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardPlanApprove, params: params)
    return try decode(value)
  }

  public func revokeTaskBoardPlan(
    id: String,
    request: TaskBoardPlanRevokeRequest
  ) async throws -> TaskBoardPlanningResponse {
    let params = try encodeParams(request, extra: ["id": .string(id)])
    let value = try await rpc(method: .taskBoardPlanRevoke, params: params)
    return try decode(value)
  }

  public func syncTaskBoard(request: TaskBoardSyncRequest) async throws -> TaskBoardSyncSummary {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardSync, params: params)
    return try decode(value)
  }

  public func syncTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardSyncSummary {
    try await syncTaskBoard(request: TaskBoardSyncRequest(status: status))
  }

  public func dispatchTaskBoard(request: TaskBoardDispatchRequest) async throws
    -> TaskBoardDispatchSummary
  {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardDispatch, params: params)
    return try decode(value)
  }

  public func evaluateTaskBoard(request: TaskBoardEvaluateRequest) async throws
    -> TaskBoardEvaluationSummary
  {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardEvaluate, params: params)
    return try decode(value)
  }

  public func auditTaskBoard(status: TaskBoardStatus? = nil) async throws -> TaskBoardAuditSummary {
    let params = try encodeParams(TaskBoardStatusFilterRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardAudit, params: params)
    return try decode(value)
  }

  public func taskBoardProjects(status: TaskBoardStatus? = nil) async throws
    -> [TaskBoardProjectSummary]
  {
    let params = try encodeParams(TaskBoardStatusFilterRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardProjects, params: params)
    return try decode(value)
  }

  public func taskBoardMachines(status: TaskBoardStatus? = nil) async throws
    -> [TaskBoardMachineSummary]
  {
    let params = try encodeParams(TaskBoardStatusFilterRequest(status: status), extra: [:])
    let value = try await rpc(method: .taskBoardMachines, params: params)
    return try decode(value)
  }

  public func taskBoardHostLocal() async throws -> TaskBoardHostMachine {
    let value = try await rpc(method: .taskBoardHostLocal)
    return try decode(value)
  }

  public func taskBoardHostList() async throws -> [TaskBoardHostMachine] {
    let value = try await rpc(method: .taskBoardHostList)
    return try decode(value)
  }

  public func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) async throws -> TaskBoardHostMachine {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardHostSetProjectTypes, params: params)
    return try decode(value)
  }

  public func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    let value = try await rpc(method: .taskBoardOrchestratorStatus)
    return try decode(value)
  }

  public func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    let value = try await rpc(method: .taskBoardOrchestratorStart)
    return try decode(value)
  }

  public func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    let value = try await rpc(method: .taskBoardOrchestratorStop)
    return try decode(value)
  }

  public func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest = TaskBoardOrchestratorRunOnceRequest()
  ) async throws
    -> TaskBoardOrchestratorRunOnceResponse
  {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorRunOnce, params: params)
    return try decode(value)
  }

  public func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    let value = try await rpc(method: .taskBoardOrchestratorSettingsGet)
    return try decode(value)
  }

  public func updateTaskBoardOrchestratorSettings(
    request: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorSettingsUpdate, params: params)
    return try decode(value)
  }

  public func taskBoardGitRuntimeConfig() async throws -> TaskBoardGitRuntimeConfig {
    let value = try await rpc(method: .taskBoardOrchestratorRuntimeConfigGet)
    return try decode(value)
  }

  public func updateTaskBoardGitRuntimeConfig(
    request: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorRuntimeConfigUpdate, params: params)
    return try decode(value)
  }

  public func syncTaskBoardGitHubTokens(
    request: TaskBoardGitHubTokensSyncRequest
  ) async throws -> TaskBoardGitHubTokensSyncResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorGitHubTokensSync, params: params)
    return try decode(value)
  }

  public func syncTaskBoardTodoistToken(
    request: TaskBoardTodoistTokenSyncRequest
  ) async throws -> TaskBoardTodoistTokenSyncResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardOrchestratorTodoistTokenSync, params: params)
    return try decode(value)
  }

  public func taskBoardGitIdentityDefaults() async throws -> TaskBoardGitIdentityDefaults {
    let value = try await rpc(method: .taskBoardGitIdentityDefaults)
    return try decode(value)
  }

  public func verifyTaskBoardGitSigning(
    request: TaskBoardGitSigningVerifyRequest
  ) async throws -> TaskBoardGitSigningVerifyResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardGitSigningVerify, params: params)
    return try decode(value)
  }

  public func drainTaskBoardGitRuntimeSecrets() async throws
    -> TaskBoardGitRuntimeDrainSecretsResponse
  {
    let value = try await rpc(method: .taskBoardGitRuntimeDrainSecrets)
    return try decode(value)
  }

  public func taskBoardPolicyPipeline() async throws -> TaskBoardPolicyPipelineDocument {
    let value = try await rpc(method: .taskBoardPolicyPipelineGet)
    return try decode(value)
  }

  public func saveTaskBoardPolicyPipelineDraft(
    request: TaskBoardPolicyPipelineSaveDraftRequest
  ) async throws -> TaskBoardPolicyPipelineSaveDraftResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyPipelineSaveDraft, params: params)
    return try decode(value)
  }

  public func simulateTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelineSimulateRequest
  ) async throws -> TaskBoardPolicyPipelineSimulationResult {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyPipelineSimulate, params: params)
    return try decode(value)
  }

  public func promoteTaskBoardPolicyPipeline(
    request: TaskBoardPolicyPipelinePromoteRequest
  ) async throws -> TaskBoardPolicyPipelinePromoteResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyPipelinePromote, params: params)
    return try decode(value)
  }

  public func taskBoardPolicyPipelineAudit() async throws -> TaskBoardPolicyPipelineAuditSummary {
    let value = try await rpc(method: .taskBoardPolicyPipelineAudit)
    return try decode(value)
  }
}
