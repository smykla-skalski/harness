import Foundation

extension HarnessMonitorStore {
  private static let taskBoardGitHubCredentialStore = TaskBoardGitHubCredentialStore()
  private static let taskBoardTodoistCredentialStore = TaskBoardTodoistCredentialStore()

  public func taskBoardGitSettingsSnapshot() async throws -> TaskBoardGitSettingsSnapshot {
    let client = try await taskBoardSettingsClient()

    async let orchestratorSettings = client.taskBoardOrchestratorSettings()
    async let runtimeConfig = client.taskBoardGitRuntimeConfig()
    async let identityDefaults = Self.fetchIdentityDefaults(client: client)
    let githubCredentials = try Self.taskBoardGitHubCredentialStore.load()
    let todoistCredentials = try Self.taskBoardTodoistCredentialStore.load()

    return try await TaskBoardGitSettingsSnapshot(
      orchestratorSettings: orchestratorSettings,
      runtimeConfig: runtimeConfig,
      githubCredentials: githubCredentials,
      todoistCredentials: todoistCredentials,
      identityDefaults: identityDefaults
    )
  }

  private static func fetchIdentityDefaults(
    client: any HarnessMonitorClientProtocol
  ) async -> TaskBoardGitIdentityDefaults {
    do {
      return try await client.taskBoardGitIdentityDefaults()
    } catch {
      return TaskBoardGitIdentityDefaults()
    }
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

      let orchestratorSettings: TaskBoardOrchestratorSettings
      do {
        orchestratorSettings = try await client.updateTaskBoardOrchestratorSettings(
          request: Self.orchestratorSettingsUpdateRequest(
            from: materializedSnapshot.orchestratorSettings)
        )
      } catch {
        presentFailureFeedback(error.localizedDescription)
        return false
      }

      do {
        _ = try await client.updateTaskBoardGitRuntimeConfig(
          request: materializedSnapshot.runtimeConfig
        )
      } catch {
        presentFailureFeedback(
          """
          Partial save: orchestrator settings saved, runtime config did not: \
          \(error.localizedDescription) - review and retry.
          """
        )
        return false
      }

      do {
        _ = try await client.syncTaskBoardGitHubTokens(
          request: materializedSnapshot.githubCredentials.syncRequest
        )
        _ = try await client.syncTaskBoardTodoistToken(
          request: materializedSnapshot.todoistCredentials.syncRequest
        )
      } catch {
        presentFailureFeedback(
          """
          Partial save: orchestrator and runtime saved, token sync did not: \
          \(error.localizedDescription) - keychain left unchanged, review and retry.
          """
        )
        return false
      }

      do {
        try Self.taskBoardGitHubCredentialStore.save(materializedSnapshot.githubCredentials)
        try Self.taskBoardTodoistCredentialStore.save(materializedSnapshot.todoistCredentials)
      } catch {
        presentFailureFeedback(
          """
          Partial save: daemon updated, but storing credentials in keychain failed: \
          \(error.localizedDescription) - review and retry.
          """
        )
        return false
      }

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
      guard
        await syncAndRefreshTaskBoardDashboard(
          using: client,
          request: TaskBoardSyncRequest(direction: .pull, dryRun: false),
          failureMessagePrefix: "Saved task board settings, but task board sync failed"
        )
      else {
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

  func syncStoredTaskBoardCredentials(using client: any HarnessMonitorClientProtocol) async {
    do {
      let githubCredentials = try Self.taskBoardGitHubCredentialStore.load()
      let todoistCredentials = try Self.taskBoardTodoistCredentialStore.load()
      _ = try await client.syncTaskBoardGitHubTokens(request: githubCredentials.syncRequest)
      _ = try await client.syncTaskBoardTodoistToken(request: todoistCredentials.syncRequest)
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
      githubInbox: settings.githubInbox,
      todoistInbox: settings.todoistInbox,
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
      githubCredentials: snapshot.githubCredentials,
      todoistCredentials: snapshot.todoistCredentials
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
        requestedReviewers: githubProject.requestedReviewers,
        enabledAutomations: githubProject.enabledAutomations
      ),
      githubInbox: settings.githubInbox,
      todoistInbox: settings.todoistInbox,
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
      sshPrivateKey: profile.sshPrivateKey,
      sshPrivateKeyPassphrase: profile.sshPrivateKeyPassphrase,
      signing: TaskBoardGitSigningConfig(
        mode: signing.mode,
        sshKeyPath: signingSSHKeyPath,
        sshPrivateKey: signing.mode == .ssh ? signing.sshPrivateKey : nil,
        sshPrivateKeyPassphrase: signing.mode == .ssh ? signing.sshPrivateKeyPassphrase : nil,
        gpgKeyId: signing.gpgKeyId,
        gpgPrivateKeyPath: signingGPGPrivateKeyPath,
        gpgPrivateKey: signing.mode == .gpg ? signing.gpgPrivateKey : nil,
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
