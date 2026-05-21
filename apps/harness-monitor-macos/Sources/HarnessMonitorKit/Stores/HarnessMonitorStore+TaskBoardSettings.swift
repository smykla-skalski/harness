// swiftlint:disable file_length
import Foundation

struct TaskBoardStoredCredentialSnapshot: Sendable {
  let githubCredentials: TaskBoardGitHubCredentialSnapshot
  let todoistCredentials: TaskBoardTodoistCredentialSnapshot
  let openRouterCredentials: TaskBoardOpenRouterCredentialSnapshot
}

public enum TaskBoardSettingsSaveOrigin: String, Sendable {
  case settingsSecretsSaveButton
  case settingsRepositoriesSaveButton
}

protocol TaskBoardGitHubCredentialPersisting: Sendable {
  func load() throws -> TaskBoardGitHubCredentialSnapshot
  func save(_ snapshot: TaskBoardGitHubCredentialSnapshot) throws
  func delete() throws
}

protocol TaskBoardTodoistCredentialPersisting: Sendable {
  func load() throws -> TaskBoardTodoistCredentialSnapshot
  func save(_ snapshot: TaskBoardTodoistCredentialSnapshot) throws
  func delete() throws
}

protocol TaskBoardOpenRouterCredentialPersisting: Sendable {
  func load() throws -> TaskBoardOpenRouterCredentialSnapshot
  func save(_ snapshot: TaskBoardOpenRouterCredentialSnapshot) throws
  func delete() throws
}

struct TaskBoardCredentialPersistence: Sendable {
  let github: any TaskBoardGitHubCredentialPersisting
  let todoist: any TaskBoardTodoistCredentialPersisting
  let openRouter: any TaskBoardOpenRouterCredentialPersisting

  /// Real Keychain in normal runs; in-memory stand-ins under xctest so test
  /// processes never trigger the macOS Keychain access prompt.
  static var defaultKeychain: Self {
    if HarnessMonitorEnvironment.current.isXCTestProcess {
      return .inMemory
    }
    return Self(
      github: TaskBoardGitHubCredentialStore(),
      todoist: TaskBoardTodoistCredentialStore(),
      openRouter: TaskBoardOpenRouterCredentialStore()
    )
  }
}

actor TaskBoardSettingsWorker {
  private let credentialPersistence: TaskBoardCredentialPersistence
  private let keyMaterialPersistence: TaskBoardKeyMaterialPersistence

  init(
    credentialPersistence: TaskBoardCredentialPersistence = .defaultKeychain,
    keyMaterialPersistence: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) {
    self.credentialPersistence = credentialPersistence
    self.keyMaterialPersistence = keyMaterialPersistence
  }

  func loadStoredCredentials() throws -> TaskBoardStoredCredentialSnapshot {
    try TaskBoardStoredCredentialSnapshot(
      githubCredentials: credentialPersistence.github.load(),
      todoistCredentials: credentialPersistence.todoist.load(),
      openRouterCredentials: credentialPersistence.openRouter.load()
    )
  }

  func hydrateKeyMaterial(into runtime: TaskBoardGitRuntimeConfig) -> TaskBoardGitRuntimeConfig {
    HarnessMonitorStore.hydrateKeyMaterial(into: runtime, keychain: keyMaterialPersistence)
  }

  fileprivate func persistLocalSecrets(
    snapshot: TaskBoardGitSettingsSnapshot,
    origin: TaskBoardSettingsSaveOrigin
  ) throws {
    switch origin {
    case .settingsSecretsSaveButton, .settingsRepositoriesSaveButton:
      break
    }
    try credentialPersistence.github.save(snapshot.githubCredentials)
    try credentialPersistence.todoist.save(snapshot.todoistCredentials)
    try credentialPersistence.openRouter.save(snapshot.openRouterCredentials)
    try HarnessMonitorStore.persistKeyMaterial(
      runtime: snapshot.runtimeConfig,
      keychain: keyMaterialPersistence
    )
  }

  private func persistKeyMaterial(runtime: TaskBoardGitRuntimeConfig) throws {
    try HarnessMonitorStore.persistKeyMaterial(runtime: runtime, keychain: keyMaterialPersistence)
  }

  func drainRuntimeSecretsIfNeeded(
    client: any HarnessMonitorClientProtocol
  ) async -> Bool {
    do {
      let response = try await client.drainTaskBoardGitRuntimeSecrets()
      if response.drained {
        try persistKeyMaterial(runtime: response.runtime)
      }
      return true
    } catch {
      return false
    }
  }

  func waitForIdle() {}
}

extension HarnessMonitorStore {
  /// Per-ownership migration flag. Managed and external daemons each carry
  /// their own on-disk config, so each one needs its own one-shot drain.
  /// Sharing a single flag would skip the drain on whichever daemon the user
  /// connected to second.
  nonisolated public static func taskBoardRuntimeSecretsMigrationKey(
    for ownership: DaemonOwnership
  ) -> String {
    "io.harnessmonitor.taskboard.runtime-secrets-migrated.\(ownership.rawValue)"
  }

  public func taskBoardGitSettingsSnapshot() async throws -> TaskBoardGitSettingsSnapshot {
    let client = try await taskBoardSettingsClient()

    await migrateRuntimeSecretsUsingWorkerIfNeeded(client: client, ownership: daemonOwnership)

    async let orchestratorSettings = client.taskBoardOrchestratorSettings()
    async let runtimeConfig = client.taskBoardGitRuntimeConfig()
    async let identityDefaults = Self.fetchIdentityDefaults(client: client)
    async let storedCredentials = taskBoardSettingsWorker.loadStoredCredentials()

    let baseRuntime = try await runtimeConfig
    let hydratedRuntime = await taskBoardSettingsWorker.hydrateKeyMaterial(into: baseRuntime)
    let credentials = try await storedCredentials

    return await TaskBoardGitSettingsSnapshot(
      orchestratorSettings: try orchestratorSettings,
      runtimeConfig: hydratedRuntime,
      githubCredentials: credentials.githubCredentials,
      todoistCredentials: credentials.todoistCredentials,
      openRouterCredentials: credentials.openRouterCredentials,
      identityDefaults: identityDefaults
    )
  }

  nonisolated static func hydrateKeyMaterial(
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

  nonisolated private static func hydrateProfile(
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

  nonisolated static func persistKeyMaterial(
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

  nonisolated private static func persistProfileKeyMaterial(
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

  nonisolated private static func fetchIdentityDefaults(
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

  private func migrateRuntimeSecretsUsingWorkerIfNeeded(
    client: any HarnessMonitorClientProtocol,
    ownership: DaemonOwnership,
    userDefaults: UserDefaults = .standard
  ) async {
    let flagKey = Self.taskBoardRuntimeSecretsMigrationKey(for: ownership)
    guard !userDefaults.bool(forKey: flagKey) else {
      return
    }
    let succeeded = await taskBoardSettingsWorker.drainRuntimeSecretsIfNeeded(client: client)
    if succeeded {
      userDefaults.set(true, forKey: flagKey)
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
  public func updateTaskBoardGitSettings(
    snapshot: TaskBoardGitSettingsSnapshot,
    origin: TaskBoardSettingsSaveOrigin
  ) async -> Bool {
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

      guard await applyTaskBoardTokenSync(client: client, snapshot: materializedSnapshot) else {
        return false
      }

      do {
        try await taskBoardSettingsWorker.persistLocalSecrets(
          snapshot: materializedSnapshot,
          origin: origin
        )
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
      presentSuccessFeedback("Saved task board settings")
      scheduleTaskBoardSettingsPostSaveRefresh(client: client)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  private func scheduleTaskBoardSettingsPostSaveRefresh(
    client: any HarnessMonitorClientProtocol
  ) {
    Task { [weak self] in
      guard let self else { return }
      await runTaskBoardSettingsPostSaveRefresh(client: client)
    }
  }

  private func runTaskBoardSettingsPostSaveRefresh(
    client: any HarnessMonitorClientProtocol
  ) async {
    async let verifyOutcome = verifyTaskBoardSigning(client: client, repository: nil)
    async let refresh: Void = refreshTaskBoardDashboardSnapshot(using: client)

    switch await verifyOutcome {
    case .skipped:
      break
    case .signed:
      break
    case .failed(let message):
      presentFailureFeedback(
        "Saved task board settings, but signing dry-run failed: \(message)"
      )
    }
    await refresh
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

  private func applyTaskBoardTokenSync(
    client: any HarnessMonitorClientProtocol,
    snapshot: TaskBoardGitSettingsSnapshot
  ) async -> Bool {
    do {
      async let githubTokens = client.syncTaskBoardGitHubTokens(
        request: snapshot.githubCredentials.syncRequest
      )
      async let todoistToken = client.syncTaskBoardTodoistToken(
        request: snapshot.todoistCredentials.syncRequest
      )
      async let openRouterToken = client.syncTaskBoardOpenRouterToken(
        request: snapshot.openRouterCredentials.syncRequest
      )
      _ = try await (githubTokens, todoistToken, openRouterToken)
      return true
    } catch {
      presentFailureFeedback(
        """
        Partial save: orchestrator and runtime saved, token sync did not: \
        \(error.localizedDescription) - keychain left unchanged, review and retry.
        """
      )
      return false
    }
  }

  private func taskBoardSettingsClient() async throws -> any HarnessMonitorClientProtocol {
    if let client {
      return client
    }
    await bootstrapIfNeeded()
    if let client {
      return client
    }

    let bootstrappedClient = try await daemonController.bootstrapClient()
    self.client = bootstrappedClient
    return bootstrappedClient
  }

  func syncStoredTaskBoardCredentials(using client: any HarnessMonitorClientProtocol) async {
    do {
      let credentials = try await taskBoardSettingsWorker.loadStoredCredentials()
      _ = try await client.syncTaskBoardGitHubTokens(
        request: credentials.githubCredentials.syncRequest
      )
      _ = try await client.syncTaskBoardTodoistToken(
        request: credentials.todoistCredentials.syncRequest
      )
      _ = try await client.syncTaskBoardOpenRouterToken(
        request: credentials.openRouterCredentials.syncRequest
      )
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

  private static func normalizedTaskBoardPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }
}
