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
}
