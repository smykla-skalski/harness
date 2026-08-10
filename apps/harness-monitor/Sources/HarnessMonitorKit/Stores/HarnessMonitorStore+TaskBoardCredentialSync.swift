import Foundation

private let taskBoardCredentialSyncRepeatInterval: TimeInterval = 30 * 60

extension HarnessMonitorStore {
  @discardableResult
  func syncStoredTaskBoardCredentials(
    using client: any HarnessMonitorClientProtocol,
    instanceID providedInstanceID: String? = nil,
    forceCredentialSync: Bool = false,
    containmentFence providedFence: LegacyContainmentFence? = nil
  ) async -> Bool {
    guard let fence = resolvedLegacyContainmentFence(providedFence) else {
      return false
    }
    guard let instanceID = providedInstanceID ?? taskBoardDatabaseInstanceID else {
      HarnessMonitorLogger.store.error("task-board credential sync skipped: database unavailable")
      return false
    }
    guard
      await migrateRuntimeSecretsUsingWorkerIfNeeded(
        client: client,
        instanceID: instanceID,
        ownership: daemonOwnership,
        containmentFence: fence
      )
    else {
      return false
    }
    return await pushStoredTaskBoardCredentials(
      using: client,
      instanceID: instanceID,
      forceCredentialSync: forceCredentialSync,
      containmentFence: fence
    )
  }

  private func pushStoredTaskBoardCredentials(
    using client: any HarnessMonitorClientProtocol,
    instanceID: String,
    forceCredentialSync: Bool,
    containmentFence fence: LegacyContainmentFence
  ) async -> Bool {
    do {
      async let storedCredentials = taskBoardSettingsWorker.loadStoredCredentials(
        instanceID: instanceID,
        ownership: daemonOwnership
      )
      async let runtimeConfig = client.taskBoardGitRuntimeConfig()
      let baseRuntime = try await runtimeConfig
      guard isCurrentLegacyContainmentFence(fence) else { return false }
      recordTaskBoardRepositoryOverrides(instanceID: instanceID, runtime: baseRuntime)
      let hydratedRuntime = await taskBoardSettingsWorker.hydrateKeyMaterial(
        into: baseRuntime,
        instanceID: instanceID,
        ownership: daemonOwnership
      )
      guard isCurrentLegacyContainmentFence(fence) else { return false }
      _ = try await client.syncTaskBoardGitRuntimeKeyMaterial(
        request: TaskBoardGitRuntimeKeyMaterialSyncRequest(runtime: hydratedRuntime)
      )
      guard isCurrentLegacyContainmentFence(fence) else { return false }
      let credentials = try await storedCredentials
      guard isCurrentLegacyContainmentFence(fence) else { return false }
      let now = Date()
      if !forceCredentialSync,
        shouldSkipStoredTaskBoardCredentialSync(
          credentials,
          instanceID: instanceID,
          now: now
        )
      {
        return true
      }
      _ = try await client.syncTaskBoardGitHubTokens(
        request: credentials.githubCredentials.syncRequest
      )
      guard isCurrentLegacyContainmentFence(fence) else { return false }
      _ = try await client.syncTaskBoardOpenRouterToken(
        request: credentials.openRouterCredentials.syncRequest
      )
      guard isCurrentLegacyContainmentFence(fence) else { return false }
      lastTaskBoardCredentialSync = TaskBoardCredentialSyncState(
        instanceID: instanceID,
        credentials: credentials,
        syncedAt: now
      )
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.error(
        "task-board credential sync failed: \(description, privacy: .public)"
      )
    }
    return isCurrentLegacyContainmentFence(fence)
  }

  func syncStoredTaskBoardCredentialsForNewDaemon(
    using client: any HarnessMonitorClientProtocol,
    validatedCapabilities: TaskBoardCapabilities? = nil,
    containmentFence providedFence: LegacyContainmentFence? = nil
  ) async -> Bool {
    guard let fence = resolvedLegacyContainmentFence(providedFence) else {
      return false
    }
    let capabilities: TaskBoardCapabilities
    if let validatedCapabilities {
      capabilities = validatedCapabilities
    } else {
      do {
        capabilities = try await databaseBackedTaskBoardCapabilities(using: client)
        try requireCurrentLegacyContainmentFence(fence)
      } catch {
        guard isCurrentLegacyContainmentFence(fence) else { return false }
        let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
        HarnessMonitorLogger.store.error(
          "task-board database capability check failed: \(description, privacy: .public)"
        )
        return false
      }
    }
    guard isCurrentLegacyContainmentFence(fence) else { return false }
    var resolvedMigrationSource = false
    if let previousID = taskBoardSecretMigrationSource(for: capabilities.instanceID) {
      resolvedMigrationSource = await migrateStoredTaskBoardSecrets(
        from: previousID,
        to: capabilities.instanceID,
        containmentFence: fence
      )
      guard isCurrentLegacyContainmentFence(fence) else { return false }
    }
    let synchronized = await syncStoredTaskBoardCredentials(
      using: client,
      instanceID: capabilities.instanceID,
      forceCredentialSync: true,
      containmentFence: fence
    )
    guard synchronized, isCurrentLegacyContainmentFence(fence) else {
      return false
    }
    adoptDatabaseBackedTaskBoard(capabilities)
    if resolvedMigrationSource {
      taskBoardRuntimeState.connection.previousDatabaseInstanceID = nil
    }
    return true
  }

  private func resolvedLegacyContainmentFence(
    _ providedFence: LegacyContainmentFence?
  ) -> LegacyContainmentFence? {
    if let providedFence {
      return isCurrentLegacyContainmentFence(providedFence) ? providedFence : nil
    }
    return try? currentLegacyContainmentFence()
  }

  func migrateRuntimeSecretsUsingWorkerIfNeeded(
    client: any HarnessMonitorClientProtocol,
    instanceID: String,
    ownership: DaemonOwnership,
    containmentFence providedFence: LegacyContainmentFence? = nil
  ) async -> Bool {
    guard let fence = resolvedLegacyContainmentFence(providedFence) else {
      return false
    }
    _ = await taskBoardSettingsWorker.completeRuntimeSecretHandoffIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: ownership
    )
    return isCurrentLegacyContainmentFence(fence)
  }

  private func shouldSkipStoredTaskBoardCredentialSync(
    _ credentials: TaskBoardStoredCredentialSnapshot,
    instanceID: String,
    now: Date
  ) -> Bool {
    if credentials.isEmpty,
      lastTaskBoardCredentialSync?.instanceID == instanceID,
      lastTaskBoardCredentialSync?.credentials.isEmpty != false
    {
      lastTaskBoardCredentialSync = TaskBoardCredentialSyncState(
        instanceID: instanceID,
        credentials: credentials,
        syncedAt: now
      )
      return true
    }
    guard let lastTaskBoardCredentialSync else {
      return false
    }
    return lastTaskBoardCredentialSync.instanceID == instanceID
      && lastTaskBoardCredentialSync.credentials == credentials
      && now.timeIntervalSince(lastTaskBoardCredentialSync.syncedAt)
        < taskBoardCredentialSyncRepeatInterval
  }
}
