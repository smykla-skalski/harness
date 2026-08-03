import Foundation

extension PreviewHarnessClient.Fixtures {
  public static let repositoriesSettings: Self = {
    let base = populated
    let baseSettings = defaultTaskBoardOrchestratorSettings
    let repositories =
      ["example/harness"]
      + (1...18).map { "example/service-\(String(format: "%02d", $0))" }
    let settings = TaskBoardOrchestratorSettings(
      stepMode: baseSettings.stepMode,
      enabledWorkflows: baseSettings.enabledWorkflows,
      dryRunDefault: baseSettings.dryRunDefault,
      dispatchStatusFilter: baseSettings.dispatchStatusFilter,
      projectDir: baseSettings.projectDir,
      githubProject: baseSettings.githubProject,
      githubInbox: TaskBoardGitHubInboxConfig(repositories: repositories),
      scheduling: baseSettings.scheduling,
      retry: baseSettings.retry,
      reviewers: baseSettings.reviewers,
      repositories: baseSettings.repositories,
      policyVersion: baseSettings.policyVersion
    )
    return Self(
      health: base.health,
      projects: base.projects,
      sessions: base.sessions,
      detail: base.detail,
      timeline: base.timeline,
      readySessionID: base.readySessionID,
      detailsBySessionID: base.detailsBySessionID,
      coreDetailsBySessionID: base.coreDetailsBySessionID,
      timelinesBySessionID: base.timelinesBySessionID,
      agentTuisBySessionID: base.agentTuisBySessionID,
      codexRunsBySessionID: base.codexRunsBySessionID,
      taskBoardOrchestratorSettings: settings,
      taskBoardGitRuntimeConfig: base.taskBoardGitRuntimeConfig,
      taskBoardGitIdentityDefaults: base.taskBoardGitIdentityDefaults,
      taskBoardItems: base.taskBoardItems,
      reviewsResponse: base.reviewsResponse
    )
  }()
}
