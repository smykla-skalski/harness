import Foundation

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

  public func updateTaskBoardProject(
    request _: TaskBoardProjectUpdateRequest
  ) async throws -> TaskBoardProject {
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

  public func taskBoardWorkingCopies() async throws -> [WorkingCopyListEntry] {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board working copies unavailable")
  }

  public func obtainTaskBoardWorkingCopy(
    repository _: String,
    allowClone _: Bool
  ) async throws -> WorkingCopyListEntry? {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board working copies unavailable")
  }

  public func deleteTaskBoardWorkingCopy(repoKeySegment _: String) async throws {
    throw HarnessMonitorAPIError.server(code: 501, message: "Task board working copies unavailable")
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
}
