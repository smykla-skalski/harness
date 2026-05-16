import Foundation

extension PreviewHarnessClient {
  public func taskBoardOrchestratorSettings() async throws -> TaskBoardOrchestratorSettings {
    try await performActionDelay()
    return await state.currentTaskBoardOrchestratorSettings()
  }

  public func updateTaskBoardOrchestratorSettings(
    request: TaskBoardOrchestratorSettingsUpdateRequest
  ) async throws -> TaskBoardOrchestratorSettings {
    try await performActionDelay()
    return await state.updateTaskBoardOrchestratorSettings(request)
  }

  public func taskBoardGitRuntimeConfig() async throws -> TaskBoardGitRuntimeConfig {
    try await performActionDelay()
    return await state.currentTaskBoardGitRuntimeConfig()
  }

  public func updateTaskBoardGitRuntimeConfig(
    request: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig {
    try await performActionDelay()
    return await state.updateTaskBoardGitRuntimeConfig(request)
  }

  public func syncTaskBoardGitHubTokens(
    request: TaskBoardGitHubTokensSyncRequest
  ) async throws -> TaskBoardGitHubTokensSyncResponse {
    try await performActionDelay()
    return await state.syncTaskBoardGitHubTokens(request)
  }

  public func syncTaskBoardTodoistToken(
    request: TaskBoardTodoistTokenSyncRequest
  ) async throws -> TaskBoardTodoistTokenSyncResponse {
    try await performActionDelay()
    return await state.syncTaskBoardTodoistToken(request)
  }

  public func taskBoardGitIdentityDefaults() async throws -> TaskBoardGitIdentityDefaults {
    try await performActionDelay()
    return await state.currentTaskBoardGitIdentityDefaults()
  }

  public func verifyTaskBoardGitSigning(
    request _: TaskBoardGitSigningVerifyRequest
  ) async throws -> TaskBoardGitSigningVerifyResponse {
    try await performActionDelay()
    return .skipped
  }

  public func drainTaskBoardGitRuntimeSecrets() async throws
    -> TaskBoardGitRuntimeDrainSecretsResponse
  {
    try await performActionDelay()
    return TaskBoardGitRuntimeDrainSecretsResponse(
      drained: false,
      runtime: TaskBoardGitRuntimeConfig()
    )
  }
}
