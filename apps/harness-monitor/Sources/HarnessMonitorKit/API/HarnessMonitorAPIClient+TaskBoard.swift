import Foundation

extension HarnessMonitorAPIClient {
  public func taskBoardCapabilities() async throws -> TaskBoardCapabilities {
    try await get("/v1/task-board/capabilities", decoder: PolicyWireCoding.decoder)
  }

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

  public func pickTaskBoardDispatch(
    request: TaskBoardDispatchPickRequest = TaskBoardDispatchPickRequest()
  ) async throws -> TaskBoardDispatchPickResult {
    let wire: TaskBoardDispatchPickResponse = try await post(
      "/v1/task-board/dispatch/pick", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardDispatchPickResult(wire: wire)
  }

  public func deliverTaskBoardDispatch(
    request: TaskBoardDispatchDeliverRequest
  ) async throws -> TaskBoardDispatchDelivery {
    let wire: TaskBoardDispatchDeliverResponse = try await post(
      "/v1/task-board/dispatch/deliver", body: request, decoder: PolicyWireCoding.decoder
    )
    return try TaskBoardDispatchDelivery(wire: wire)
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
    let wire: TaskBoardOrchestratorStatusWire = try await get(
      "/v1/task-board/orchestrator/status", decoder: PolicyWireCoding.decoder
    )
    return TaskBoardOrchestratorStatus(wire: wire)
  }

  public func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    let wire: TaskBoardOrchestratorStatusWire = try await post(
      "/v1/task-board/orchestrator/start", body: EmptyBody(), decoder: PolicyWireCoding.decoder
    )
    return TaskBoardOrchestratorStatus(wire: wire)
  }

  public func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    let wire: TaskBoardOrchestratorStatusWire = try await post(
      "/v1/task-board/orchestrator/stop", body: EmptyBody(), decoder: PolicyWireCoding.decoder
    )
    return TaskBoardOrchestratorStatus(wire: wire)
  }

  public func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest = TaskBoardOrchestratorRunOnceRequest()
  ) async throws
    -> TaskBoardOrchestratorRunOnceResponse
  {
    let wire: TaskBoardOrchestratorStatusWire = try await post(
      "/v1/task-board/orchestrator/run-once", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardOrchestratorStatus(wire: wire)
  }

  public func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    let wire: TaskBoardOrchestratorSettingsWire = try await get(
      "/v1/task-board/orchestrator/settings", decoder: PolicyWireCoding.decoder
    )
    return TaskBoardOrchestratorSettings(wire: wire)
  }

  public func updateTaskBoardOrchestratorSettings(
    request: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    let wire: TaskBoardOrchestratorSettingsWire = try await put(
      "/v1/task-board/orchestrator/settings", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardOrchestratorSettings(wire: wire)
  }

  public func taskBoardGitRuntimeConfig() async throws -> TaskBoardGitRuntimeConfig {
    let wire: TaskBoardGitRuntimeConfigWire = try await get(
      "/v1/task-board/orchestrator/runtime-config", decoder: PolicyWireCoding.decoder
    )
    return TaskBoardGitRuntimeConfig(wire: wire)
  }

  public func updateTaskBoardGitRuntimeConfig(
    request: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig {
    let wire: TaskBoardGitRuntimeConfigWire = try await put(
      "/v1/task-board/orchestrator/runtime-config", body: request,
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardGitRuntimeConfig(wire: wire)
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
    let wire: TaskBoardGitSigningVerifyResponseWire = try await post(
      "/v1/task-board/git/signing/verify", body: request, decoder: PolicyWireCoding.decoder
    )
    return TaskBoardGitSigningVerifyResponse(wire: wire)
  }

  public func syncTaskBoardGitRuntimeKeyMaterial(
    request: TaskBoardGitRuntimeKeyMaterialSyncRequest
  ) async throws -> TaskBoardGitRuntimeKeyMaterialSyncResponse {
    try await put(
      "/v1/task-board/git/runtime/key-material",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func prepareTaskBoardGitRuntimeSecretHandoff() async throws
    -> TaskBoardGitRuntimeSecretHandoffPrepareResponse
  {
    let wire: TaskBoardGitRuntimeSecretHandoffPrepareResponseWire = try await post(
      "/v1/task-board/git/runtime/secret-handoff/prepare",
      body: TaskBoardGitRuntimeSecretHandoffPrepareRequest(),
      decoder: PolicyWireCoding.decoder
    )
    return TaskBoardGitRuntimeSecretHandoffPrepareResponse(wire: wire)
  }

  public func acknowledgeTaskBoardGitRuntimeSecretHandoff(
    request: TaskBoardGitRuntimeSecretHandoffAckRequest
  ) async throws -> TaskBoardGitRuntimeSecretHandoffAckResponse {
    try await post(
      "/v1/task-board/git/runtime/secret-handoff/ack",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  private func taskBoardQueryItems(status: TaskBoardStatus?) -> [URLQueryItem] {
    guard let status else {
      return []
    }
    return [URLQueryItem(name: "status", value: status.rawValue)]
  }
}
