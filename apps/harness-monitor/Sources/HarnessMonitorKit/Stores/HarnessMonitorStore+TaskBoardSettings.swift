import Foundation

struct TaskBoardCredentialSyncState: Sendable {
  let instanceID: String
  let credentials: TaskBoardStoredCredentialSnapshot
  let syncedAt: Date
}

struct TaskBoardConnectionState: Sendable {
  var databaseInstanceID: String?
  var databaseAccessGeneration: UInt64 = 0
  var databaseAccessSuspended = false
  var previousDatabaseInstanceID: String?
  /// Last non-nil instance id ever connected this session. Unlike
  /// `databaseInstanceID` it survives disconnects, so a switch to a different
  /// daemon can still identify the scope to migrate from.
  var lastConnectedDatabaseInstanceID: String?
  /// Repository override slugs last seen in each daemon's runtime config,
  /// keyed by instance id. Per-repo key material is Keychain-hashed and cannot
  /// be enumerated, so this remembers which repos carry it for migration.
  var databaseRepositoryOverrideSlugs: [String: Set<String>] = [:]
  var credentialSync: TaskBoardCredentialSyncState?
  var secretMigrationConsent: TaskBoardSecretMigrationConsentState?
}

extension HarnessMonitorStore {
  var taskBoardDatabaseInstanceID: String? {
    get { taskBoardRuntimeState.connection.databaseInstanceID }
    set { taskBoardRuntimeState.connection.databaseInstanceID = newValue }
  }

  var taskBoardPreviousDatabaseInstanceID: String? {
    taskBoardRuntimeState.connection.previousDatabaseInstanceID
  }

  var lastTaskBoardCredentialSync: TaskBoardCredentialSyncState? {
    get { taskBoardRuntimeState.connection.credentialSync }
    set { taskBoardRuntimeState.connection.credentialSync = newValue }
  }

  public func taskBoardGitSettingsSnapshot() async throws -> TaskBoardGitSettingsSnapshot {
    let access = try await taskBoardSettingsClient()
    let client = access.client
    let instanceID = access.instanceID

    let handoffCompleted = await migrateRuntimeSecretsUsingWorkerIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: daemonOwnership,
      accessFence: access.accessFence
    )
    guard handoffCompleted else {
      throw HarnessMonitorAPIError.server(
        code: 503,
        message: "Task Board runtime secret handoff did not complete"
      )
    }
    try requireCurrentTaskBoardClientAccess(access)

    async let orchestratorSettings = client.taskBoardOrchestratorSettings()
    async let runtimeConfig = client.taskBoardGitRuntimeConfig()
    async let identityDefaults = Self.fetchIdentityDefaults(client: client)
    async let storedCredentials = taskBoardSettingsWorker.loadStoredCredentials(
      instanceID: instanceID,
      ownership: daemonOwnership
    )

    let baseRuntime = try await runtimeConfig
    try requireCurrentTaskBoardClientAccess(access)
    recordTaskBoardRepositoryOverrides(instanceID: instanceID, runtime: baseRuntime)
    let hydratedRuntime = await taskBoardSettingsWorker.hydrateKeyMaterial(
      into: baseRuntime,
      instanceID: instanceID,
      ownership: daemonOwnership
    )
    let credentials = try await storedCredentials
    let resolvedOrchestratorSettings = try await orchestratorSettings
    let resolvedIdentityDefaults = await identityDefaults
    try requireCurrentTaskBoardClientAccess(access)

    return TaskBoardGitSettingsSnapshot(
      orchestratorSettings: resolvedOrchestratorSettings,
      runtimeConfig: hydratedRuntime,
      githubCredentials: credentials.githubCredentials,
      openRouterCredentials: credentials.openRouterCredentials,
      identityDefaults: resolvedIdentityDefaults
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
  public func updateTaskBoardGitSettings(
    snapshot: TaskBoardGitSettingsSnapshot,
    origin: TaskBoardSettingsSaveOrigin,
    preservingPathsFrom pathBaseline: TaskBoardGitSettingsPathBaseline? = nil
  ) async -> Bool {
    await acquireTaskBoardOrchestratorSettingsMutationLock()
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
      releaseTaskBoardOrchestratorSettingsMutationLock()
    }

    do {
      let access = try await taskBoardSettingsClient()
      let client = access.client
      let instanceID = access.instanceID
      let materializedSnapshot = try await materializeTaskBoardGitSettings(
        snapshot,
        preservingPathsFrom: pathBaseline
      )
      try requireCurrentTaskBoardClientAccess(access)

      let orchestratorSettings: TaskBoardOrchestratorSettings
      do {
        orchestratorSettings = try await client.updateTaskBoardOrchestratorSettings(
          request: Self.orchestratorSettingsUpdateRequest(
            from: materializedSnapshot.orchestratorSettings)
        )
        try requireCurrentTaskBoardClientAccess(access)
      } catch {
        presentFailureFeedback(error.localizedDescription)
        return false
      }

      do {
        _ = try await client.updateTaskBoardGitRuntimeConfig(
          request: materializedSnapshot.runtimeConfig
        )
        try requireCurrentTaskBoardClientAccess(access)
      } catch {
        presentFailureFeedback(
          """
          Partial save: orchestrator settings saved, runtime config did not: \
          \(error.localizedDescription) - review and retry.
          """
        )
        return false
      }

      guard
        await applyTaskBoardTokenSync(
          access: access,
          snapshot: materializedSnapshot,
          instanceID: instanceID
        )
      else {
        return false
      }

      do {
        try await taskBoardSettingsWorker.persistLocalSecrets(
          snapshot: materializedSnapshot,
          origin: origin,
          instanceID: instanceID,
          ownership: daemonOwnership
        )
        try requireCurrentTaskBoardClientAccess(access)
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
        confirmTaskBoardOrchestratorSettings(orchestratorSettings)
        globalTaskBoardOrchestratorStatus = TaskBoardOrchestratorStatus(
          enabled: status.enabled,
          running: status.running,
          stepMode: orchestratorSettings.stepMode,
          heldDispatches: status.heldDispatches,
          currentTick: status.currentTick,
          lastRun: status.lastRun,
          workflowExecutionCounts: status.workflowExecutionCounts,
          automation: status.automation,
          settings: orchestratorSettings
        )
      }

      recordRequestSuccess()
      presentSuccessFeedback("Saved task board settings")
      scheduleTaskBoardSettingsPostSaveRefresh(access: access)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  private func scheduleTaskBoardSettingsPostSaveRefresh(
    access: TaskBoardClientAccess
  ) {
    Task { [weak self] in
      guard let self else { return }
      await runTaskBoardSettingsPostSaveRefresh(access: access)
    }
  }

  private func runTaskBoardSettingsPostSaveRefresh(
    access: TaskBoardClientAccess
  ) async {
    guard (try? requireCurrentTaskBoardClientAccess(access)) != nil else { return }
    let client = access.client
    async let verifyOutcome = verifyTaskBoardSigning(client: client, repository: nil)
    async let refresh: Void = refreshTaskBoardDashboardSnapshot(using: client)

    let resolvedVerifyOutcome = await verifyOutcome
    guard (try? requireCurrentTaskBoardClientAccess(access)) != nil else {
      await refresh
      return
    }
    switch resolvedVerifyOutcome {
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
    access: TaskBoardClientAccess,
    snapshot: TaskBoardGitSettingsSnapshot,
    instanceID: String
  ) async -> Bool {
    do {
      async let githubTokens = access.client.syncTaskBoardGitHubTokens(
        request: snapshot.githubCredentials.syncRequest
      )
      async let openRouterToken = access.client.syncTaskBoardOpenRouterToken(
        request: snapshot.openRouterCredentials.syncRequest
      )
      _ = try await (githubTokens, openRouterToken)
      try requireCurrentTaskBoardClientAccess(access)
      lastTaskBoardCredentialSync = TaskBoardCredentialSyncState(
        instanceID: instanceID,
        credentials: TaskBoardStoredCredentialSnapshot(
          githubCredentials: snapshot.githubCredentials,
          openRouterCredentials: snapshot.openRouterCredentials
        ),
        syncedAt: Date()
      )
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

  private func taskBoardSettingsClient() async throws -> TaskBoardClientAccess {
    if let client {
      return try await requireCurrentDatabaseBackedTaskBoardClient(client)
    }
    await bootstrapIfNeeded()
    if let client {
      return try await requireCurrentDatabaseBackedTaskBoardClient(client)
    }

    return try await bootstrapSynchronizedTaskBoardClient()
  }

}
