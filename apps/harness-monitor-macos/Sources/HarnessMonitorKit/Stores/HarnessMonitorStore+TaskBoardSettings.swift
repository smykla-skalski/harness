import Foundation

extension HarnessMonitorStore {
  private static let taskBoardGitHubCredentialStore = TaskBoardGitHubCredentialStore()

  public func taskBoardGitSettingsSnapshot() async throws -> TaskBoardGitSettingsSnapshot {
    guard let client else {
      throw HarnessMonitorAPIError.server(code: 503, message: "Task board unavailable.")
    }

    async let orchestratorSettings = client.taskBoardOrchestratorSettings()
    async let runtimeConfig = client.taskBoardGitRuntimeConfig()
    let credentials = try Self.taskBoardGitHubCredentialStore.load()

    return try await TaskBoardGitSettingsSnapshot(
      orchestratorSettings: orchestratorSettings,
      runtimeConfig: runtimeConfig,
      credentials: credentials
    )
  }

  @discardableResult
  public func updateTaskBoardGitSettings(snapshot: TaskBoardGitSettingsSnapshot) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      async let updatedOrchestrator = client.updateTaskBoardOrchestratorSettings(
        request: Self.orchestratorSettingsUpdateRequest(from: snapshot.orchestratorSettings)
      )
      async let updatedRuntime = client.updateTaskBoardGitRuntimeConfig(request: snapshot.runtimeConfig)

      let orchestratorSettings = try await updatedOrchestrator
      _ = try await updatedRuntime
      try Self.taskBoardGitHubCredentialStore.save(snapshot.credentials)
      _ = try await client.syncTaskBoardGitHubTokens(request: snapshot.credentials.syncRequest)

      if let status = globalTaskBoardOrchestratorStatus {
        globalTaskBoardOrchestratorStatus = TaskBoardOrchestratorStatus(
          enabled: status.enabled,
          running: status.running,
          currentTick: status.currentTick,
          lastRun: status.lastRun,
          workflowExecutionCounts: status.workflowExecutionCounts,
          settings: orchestratorSettings
        )
      }
      recordRequestSuccess()
      await refreshTaskBoardDashboard()
      presentSuccessFeedback("Saved task board settings")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  func syncStoredTaskBoardGitHubCredentials(using client: any HarnessMonitorClientProtocol) async {
    do {
      let credentials = try Self.taskBoardGitHubCredentialStore.load()
      _ = try await client.syncTaskBoardGitHubTokens(request: credentials.syncRequest)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.error(
        "task-board credential sync failed: \(description, privacy: .public)"
      )
    }
  }

  private static func orchestratorSettingsUpdateRequest(
    from settings: TaskBoardOrchestratorSettings
  ) -> TaskBoardOrchestratorSettingsUpdateRequest {
    TaskBoardOrchestratorSettingsUpdateRequest(
      enabledWorkflows: settings.enabledWorkflows,
      dryRunDefault: settings.dryRunDefault,
      dispatchStatusFilter: settings.dispatchStatusFilter,
      clearDispatchStatusFilter: settings.dispatchStatusFilter == nil,
      projectDir: settings.projectDir,
      clearProjectDir: settings.projectDir == nil,
      githubProject: settings.githubProject,
      policyVersion: settings.policyVersion
    )
  }
}
