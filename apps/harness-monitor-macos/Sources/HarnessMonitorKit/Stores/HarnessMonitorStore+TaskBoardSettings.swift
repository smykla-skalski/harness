import Foundation

extension HarnessMonitorStore {
  private static let taskBoardGitHubCredentialStore = TaskBoardGitHubCredentialStore()

  public func taskBoardGitSettingsSnapshot() async throws -> TaskBoardGitSettingsSnapshot {
    let client = try await taskBoardSettingsClient()

    async let orchestratorSettings = client.taskBoardOrchestratorSettings()
    async let runtimeConfig = client.taskBoardGitRuntimeConfig()
    let credentials = try Self.taskBoardGitHubCredentialStore.load()

    return try await TaskBoardGitSettingsSnapshot(
      orchestratorSettings: orchestratorSettings,
      runtimeConfig: runtimeConfig,
      credentials: credentials
    )
  }

  public func authorizeTaskBoardPath(
    _ url: URL,
    kind: BookmarkStore.Record.Kind
  ) async throws -> String {
    if let bookmarkStore {
      let record = try await url.withSecurityScopeAsync { scopedURL in
        try await bookmarkStore.add(url: scopedURL, kind: kind)
      }
      return record.lastResolvedPath
    }
    return Self.normalizedTaskBoardPath(url.path)
  }

  @discardableResult
  public func updateTaskBoardGitSettings(snapshot: TaskBoardGitSettingsSnapshot) async -> Bool {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let client = try await taskBoardSettingsClient()
      let materializedSnapshot = try await materializeTaskBoardGitSettings(snapshot)
      async let updatedOrchestrator = client.updateTaskBoardOrchestratorSettings(
        request: Self.orchestratorSettingsUpdateRequest(
          from: materializedSnapshot.orchestratorSettings)
      )
      async let updatedRuntime = client.updateTaskBoardGitRuntimeConfig(
        request: materializedSnapshot.runtimeConfig
      )

      let orchestratorSettings = try await updatedOrchestrator
      _ = try await updatedRuntime
      try Self.taskBoardGitHubCredentialStore.save(materializedSnapshot.credentials)
      _ = try await client.syncTaskBoardGitHubTokens(
        request: materializedSnapshot.credentials.syncRequest
      )

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
      guard await syncAndRefreshTaskBoardDashboard(
        using: client,
        failureMessagePrefix: "Saved task board settings, but task board sync failed"
      ) else {
        return false
      }
      presentSuccessFeedback("Saved task board settings")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  private func taskBoardSettingsClient() async throws -> any HarnessMonitorClientProtocol {
    if let client {
      return client
    }

    let bootstrappedClient = try await daemonController.bootstrapClient()
    self.client = bootstrappedClient
    return bootstrappedClient
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

  private func materializeTaskBoardGitSettings(
    _ snapshot: TaskBoardGitSettingsSnapshot
  ) async throws -> TaskBoardGitSettingsSnapshot {
    TaskBoardGitSettingsSnapshot(
      orchestratorSettings: try await materializeTaskBoardOrchestratorSettings(
        snapshot.orchestratorSettings
      ),
      runtimeConfig: try await materializeTaskBoardGitRuntimeConfig(snapshot.runtimeConfig),
      credentials: snapshot.credentials
    )
  }

  private func materializeTaskBoardOrchestratorSettings(
    _ settings: TaskBoardOrchestratorSettings
  ) async throws -> TaskBoardOrchestratorSettings {
    let githubProject = settings.githubProject
    return TaskBoardOrchestratorSettings(
      enabledWorkflows: settings.enabledWorkflows,
      dryRunDefault: settings.dryRunDefault,
      dispatchStatusFilter: settings.dispatchStatusFilter,
      projectDir: try await materializeTaskBoardPath(
        settings.projectDir,
        kind: .taskBoardDirectory,
        isDirectory: true
      ),
      githubProject: TaskBoardGitHubProjectConfig(
        owner: githubProject.owner,
        repo: githubProject.repo,
        checkoutPath: try await materializeTaskBoardPath(
          githubProject.checkoutPath,
          kind: .taskBoardDirectory,
          isDirectory: true
        ) ?? "",
        defaultBranch: githubProject.defaultBranch,
        branchPrefix: githubProject.branchPrefix,
        mergeMethod: githubProject.mergeMethod,
        labels: githubProject.labels,
        protectedPaths: githubProject.protectedPaths,
        enabledAutomations: githubProject.enabledAutomations
      ),
      policyVersion: settings.policyVersion
    )
  }

  private func materializeTaskBoardGitRuntimeConfig(
    _ config: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig {
    var repositoryOverrides: [TaskBoardGitRepositoryOverride] = []
    repositoryOverrides.reserveCapacity(config.repositoryOverrides.count)
    for override in config.repositoryOverrides {
      repositoryOverrides.append(
        TaskBoardGitRepositoryOverride(
          repository: override.repository,
          profile: try await materializeTaskBoardGitRuntimeProfile(override.profile)
        )
      )
    }
    return TaskBoardGitRuntimeConfig(
      global: try await materializeTaskBoardGitRuntimeProfile(config.global),
      repositoryOverrides: repositoryOverrides
    )
  }

  private func materializeTaskBoardGitRuntimeProfile(
    _ profile: TaskBoardGitRuntimeProfile
  ) async throws -> TaskBoardGitRuntimeProfile {
    let signing = profile.signing
    let signingSSHKeyPath: String? =
      if signing.mode == .ssh {
        try await materializeTaskBoardPath(
          signing.sshKeyPath,
          kind: .taskBoardKeyFile,
          isDirectory: false
        )
      } else {
        nil
      }
    let signingGPGPrivateKeyPath: String? =
      if signing.mode == .gpg {
        try await materializeTaskBoardPath(
          signing.gpgPrivateKeyPath,
          kind: .taskBoardKeyFile,
          isDirectory: false
        )
      } else {
        nil
      }

    return TaskBoardGitRuntimeProfile(
      authorName: profile.authorName,
      authorEmail: profile.authorEmail,
      sshKeyPath: try await materializeTaskBoardPath(
        profile.sshKeyPath,
        kind: .taskBoardKeyFile,
        isDirectory: false
      ),
      signing: TaskBoardGitSigningConfig(
        mode: signing.mode,
        sshKeyPath: signingSSHKeyPath,
        gpgKeyId: signing.gpgKeyId,
        gpgPrivateKeyPath: signingGPGPrivateKeyPath,
        gpgPrivateKeyPassphrase: signing.mode == .gpg ? signing.gpgPrivateKeyPassphrase : nil
      )
    )
  }

  private func materializeTaskBoardPath(
    _ rawPath: String?,
    kind: BookmarkStore.Record.Kind,
    isDirectory: Bool
  ) async throws -> String? {
    guard let rawPath else { return nil }
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }
    return try await authorizeTaskBoardPath(
      URL(fileURLWithPath: trimmed, isDirectory: isDirectory),
      kind: kind
    )
  }

  private static func normalizedTaskBoardPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }
}
