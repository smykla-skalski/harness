import Foundation

extension PreviewHarnessClientState {
  func currentTaskBoardOrchestratorSettings() -> TaskBoardOrchestratorSettings {
    taskBoardOrchestratorSettings
  }

  func updateTaskBoardOrchestratorSettings(
    _ request: TaskBoardOrchestratorSettingsUpdateRequest
  ) -> TaskBoardOrchestratorSettings {
    let current = taskBoardOrchestratorSettings
    taskBoardOrchestratorSettings = TaskBoardOrchestratorSettings(
      enabledWorkflows: request.enabledWorkflows ?? current.enabledWorkflows,
      dryRunDefault: request.dryRunDefault ?? current.dryRunDefault,
      dispatchStatusFilter: request.clearDispatchStatusFilter
        ? nil
        : (request.dispatchStatusFilter ?? current.dispatchStatusFilter),
      projectDir: request.clearProjectDir ? nil : (request.projectDir ?? current.projectDir),
      githubProject: request.githubProject ?? current.githubProject,
      githubInbox: request.githubInbox ?? current.githubInbox,
      todoistInbox: request.todoistInbox ?? current.todoistInbox,
      policyVersion: request.policyVersion ?? current.policyVersion
    )
    return taskBoardOrchestratorSettings
  }

  func currentTaskBoardGitRuntimeConfig() -> TaskBoardGitRuntimeConfig {
    taskBoardGitRuntimeConfig
  }

  func updateTaskBoardGitRuntimeConfig(
    _ request: TaskBoardGitRuntimeConfig
  ) -> TaskBoardGitRuntimeConfig {
    taskBoardGitRuntimeConfig = request
    return taskBoardGitRuntimeConfig
  }

  func syncTaskBoardGitHubTokens(
    _ request: TaskBoardGitHubTokensSyncRequest
  ) -> TaskBoardGitHubTokensSyncResponse {
    taskBoardGitHubTokens = request
    return TaskBoardGitHubTokensSyncResponse(
      globalTokenConfigured: request.globalToken?.isEmpty == false,
      repositoryTokenCount: request.repositoryTokens.filter { !$0.token.isEmpty }.count
    )
  }

  func syncTaskBoardTodoistToken(
    _ request: TaskBoardTodoistTokenSyncRequest
  ) -> TaskBoardTodoistTokenSyncResponse {
    taskBoardTodoistToken = request
    return TaskBoardTodoistTokenSyncResponse(tokenConfigured: request.token?.isEmpty == false)
  }

  func syncTaskBoardOpenRouterToken(
    _ request: TaskBoardOpenRouterTokenSyncRequest
  ) -> TaskBoardOpenRouterTokenSyncResponse {
    taskBoardOpenRouterToken = request
    return TaskBoardOpenRouterTokenSyncResponse(
      tokenConfigured: request.token?.isEmpty == false
    )
  }

  func currentTaskBoardGitIdentityDefaults() -> TaskBoardGitIdentityDefaults {
    taskBoardGitIdentityDefaults
  }
}
