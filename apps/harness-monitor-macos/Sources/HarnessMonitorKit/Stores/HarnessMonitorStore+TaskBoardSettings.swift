import Foundation

extension HarnessMonitorStore {
  private static let taskBoardGitHubCredentialStore = TaskBoardGitHubCredentialStore()
  private static let taskBoardTodoistCredentialStore = TaskBoardTodoistCredentialStore()

  /// Per-ownership migration flag. Managed and external daemons each carry
  /// their own on-disk config, so each one needs its own one-shot drain.
  /// Sharing a single flag would skip the drain on whichever daemon the user
  /// connected to second.
  public static func taskBoardRuntimeSecretsMigrationKey(
    for ownership: DaemonOwnership
  ) -> String {
    "io.harnessmonitor.taskboard.runtime-secrets-migrated.\(ownership.rawValue)"
  }

  public func taskBoardGitSettingsSnapshot() async throws -> TaskBoardGitSettingsSnapshot {
    let client = try await taskBoardSettingsClient()

    await Self.migrateRuntimeSecretsIfNeeded(client: client, ownership: daemonOwnership)

    async let orchestratorSettings = client.taskBoardOrchestratorSettings()
    async let runtimeConfig = client.taskBoardGitRuntimeConfig()
    async let identityDefaults = Self.fetchIdentityDefaults(client: client)
    let githubCredentials = try Self.taskBoardGitHubCredentialStore.load()
    let todoistCredentials = try Self.taskBoardTodoistCredentialStore.load()

    let baseRuntime = try await runtimeConfig
    let hydratedRuntime = Self.hydrateKeyMaterial(into: baseRuntime)

    return await TaskBoardGitSettingsSnapshot(
      orchestratorSettings: try orchestratorSettings,
      runtimeConfig: hydratedRuntime,
      githubCredentials: githubCredentials,
      todoistCredentials: todoistCredentials,
      identityDefaults: identityDefaults
    )
  }

  private static func hydrateKeyMaterial(
    into runtime: TaskBoardGitRuntimeConfig,
    keychain: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) -> TaskBoardGitRuntimeConfig {
    TaskBoardGitRuntimeConfig(
      global: hydrateProfile(runtime.global, scope: .global, keychain: keychain),
      repositoryOverrides: runtime.repositoryOverrides.map { override in
        TaskBoardGitRepositoryOverride(
          repository: override.repository,
          profile: hydrateProfile(
            override.profile,
            scope: .repository(override.repository),
            keychain: keychain
          )
        )
      }
    )
  }

  private static func hydrateProfile(
    _ profile: TaskBoardGitRuntimeProfile,
    scope: TaskBoardKeyMaterialStore.Scope,
    keychain: TaskBoardKeyMaterialPersistence
  ) -> TaskBoardGitRuntimeProfile {
    let ssh = (try? keychain.ssh.load(scope: scope)) ?? TaskBoardKeyMaterialSnapshot()
    let signingSsh =
      (try? keychain.signingSsh.load(scope: scope)) ?? TaskBoardKeyMaterialSnapshot()
    let gpg = (try? keychain.gpg.load(scope: scope)) ?? TaskBoardKeyMaterialSnapshot()

    let signing = TaskBoardGitSigningConfig(
      mode: profile.signing.mode,
      sshKeyPath: profile.signing.sshKeyPath,
      sshPrivateKey: signingSsh.privateKey ?? profile.signing.sshPrivateKey,
      sshPrivateKeyPassphrase: signingSsh.passphrase ?? profile.signing.sshPrivateKeyPassphrase,
      gpgKeyId: profile.signing.gpgKeyId,
      gpgPrivateKeyPath: profile.signing.gpgPrivateKeyPath,
      gpgPrivateKey: gpg.privateKey ?? profile.signing.gpgPrivateKey,
      gpgPrivateKeyPassphrase: gpg.passphrase ?? profile.signing.gpgPrivateKeyPassphrase
    )
    return TaskBoardGitRuntimeProfile(
      authorName: profile.authorName,
      authorEmail: profile.authorEmail,
      sshKeyPath: profile.sshKeyPath,
      sshPrivateKey: ssh.privateKey ?? profile.sshPrivateKey,
      sshPrivateKeyPassphrase: ssh.passphrase ?? profile.sshPrivateKeyPassphrase,
      signing: signing
    )
  }

  static func persistKeyMaterial(
    runtime: TaskBoardGitRuntimeConfig,
    keychain: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) throws {
    try persistProfileKeyMaterial(runtime.global, scope: .global, keychain: keychain)
    for override in runtime.repositoryOverrides {
      try persistProfileKeyMaterial(
        override.profile,
        scope: .repository(override.repository),
        keychain: keychain
      )
    }
  }

  private static func persistProfileKeyMaterial(
    _ profile: TaskBoardGitRuntimeProfile,
    scope: TaskBoardKeyMaterialStore.Scope,
    keychain: TaskBoardKeyMaterialPersistence
  ) throws {
    try keychain.ssh.save(
      TaskBoardKeyMaterialSnapshot(
        privateKey: profile.sshPrivateKey,
        passphrase: profile.sshPrivateKeyPassphrase,
        keyPath: profile.sshKeyPath
      ),
      scope: scope
    )
    try keychain.signingSsh.save(
      TaskBoardKeyMaterialSnapshot(
        privateKey: profile.signing.sshPrivateKey,
        passphrase: profile.signing.sshPrivateKeyPassphrase,
        keyPath: profile.signing.sshKeyPath
      ),
      scope: scope
    )
    try keychain.gpg.save(
      TaskBoardKeyMaterialSnapshot(
        privateKey: profile.signing.gpgPrivateKey,
        passphrase: profile.signing.gpgPrivateKeyPassphrase,
        keyPath: profile.signing.gpgPrivateKeyPath,
        keyId: profile.signing.gpgKeyId
      ),
      scope: scope
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

  static func migrateRuntimeSecretsIfNeeded(
    client: any HarnessMonitorClientProtocol,
    ownership: DaemonOwnership,
    userDefaults: UserDefaults = .standard,
    keychain: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) async {
    let flagKey = taskBoardRuntimeSecretsMigrationKey(for: ownership)
    guard !userDefaults.bool(forKey: flagKey) else {
      return
    }
    do {
      let response = try await client.drainTaskBoardGitRuntimeSecrets()
      if response.drained {
        try persistKeyMaterial(runtime: response.runtime, keychain: keychain)
      }
      userDefaults.set(true, forKey: flagKey)
    } catch {
      // Older daemons (wire version 1) don't expose the drain endpoint; the
      // version-skew banner already tells the user to upgrade. Leave the
      // migration flag unset so we retry on the next snapshot fetch.
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
        try Self.persistKeyMaterial(runtime: materializedSnapshot.runtimeConfig)
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

      let verifyOutcome = await verifyTaskBoardSigning(client: client, repository: nil)
      switch verifyOutcome {
      case .skipped:
        break
      case .signed:
        break
      case .failed(let message):
        presentFailureFeedback(
          "Saved task board settings, but signing dry-run failed: \(message)"
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

  private func verifyTaskBoardSigning(
    client: any HarnessMonitorClientProtocol,
    repository: String?
  ) async -> TaskBoardGitSigningVerifyResponse {
    do {
      return try await client.verifyTaskBoardGitSigning(
        request: TaskBoardGitSigningVerifyRequest(repository: repository)
      )
    } catch {
      return .failed(message: error.localizedDescription)
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
