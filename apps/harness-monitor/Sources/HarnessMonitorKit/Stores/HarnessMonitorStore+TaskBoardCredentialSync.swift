import Foundation

private let taskBoardCredentialSyncRepeatInterval: TimeInterval = 30 * 60

extension HarnessMonitorStore {
  @discardableResult
  func syncStoredTaskBoardCredentials(
    using client: any HarnessMonitorClientProtocol,
    instanceID providedInstanceID: String? = nil,
    forceCredentialSync: Bool = false,
    containmentFence providedFence: LegacyContainmentFence? = nil,
    connectionFence: ConnectionAttemptFence? = nil
  ) async -> Bool {
    guard
      let fence = resolvedLegacyContainmentFence(
        providedFence ?? connectionFence?.containment
      ),
      isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence)
    else {
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
        containmentFence: fence,
        connectionFence: connectionFence
      )
    else {
      return false
    }
    return await pushStoredTaskBoardCredentials(
      using: client,
      instanceID: instanceID,
      forceCredentialSync: forceCredentialSync,
      containmentFence: fence,
      connectionFence: connectionFence
    )
  }

  private func pushStoredTaskBoardCredentials(
    using client: any HarnessMonitorClientProtocol,
    instanceID: String,
    forceCredentialSync: Bool,
    containmentFence fence: LegacyContainmentFence,
    connectionFence: ConnectionAttemptFence?
  ) async -> Bool {
    do {
      async let storedCredentials = taskBoardSettingsWorker.loadStoredCredentials(
        instanceID: instanceID,
        ownership: daemonOwnership
      )
      async let runtimeConfig = client.taskBoardGitRuntimeConfig()
      let baseRuntime = try await runtimeConfig
      guard isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence) else {
        return false
      }
      recordTaskBoardRepositoryOverrides(instanceID: instanceID, runtime: baseRuntime)
      let hydratedRuntime = await taskBoardSettingsWorker.hydrateKeyMaterial(
        into: baseRuntime,
        instanceID: instanceID,
        ownership: daemonOwnership
      )
      guard isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence) else {
        return false
      }
      _ = try await client.syncTaskBoardGitRuntimeKeyMaterial(
        request: TaskBoardGitRuntimeKeyMaterialSyncRequest(runtime: hydratedRuntime)
      )
      guard isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence) else {
        return false
      }
      let credentials = try await storedCredentials
      guard isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence) else {
        return false
      }
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
      guard isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence) else {
        return false
      }
      _ = try await client.syncTaskBoardOpenRouterToken(
        request: credentials.openRouterCredentials.syncRequest
      )
      guard isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence) else {
        return false
      }
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
    return isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence)
  }

  func syncStoredTaskBoardCredentialsForNewDaemon(
    using client: any HarnessMonitorClientProtocol,
    validatedCapabilities: TaskBoardCapabilities? = nil,
    containmentFence providedFence: LegacyContainmentFence? = nil,
    connectionFence: ConnectionAttemptFence? = nil
  ) async -> Bool {
    guard
      let fence = resolvedLegacyContainmentFence(
        providedFence ?? connectionFence?.containment
      ),
      isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence)
    else {
      return false
    }
    let capabilities: TaskBoardCapabilities
    if let validatedCapabilities {
      capabilities = validatedCapabilities
    } else {
      do {
        capabilities = try await databaseBackedTaskBoardCapabilities(using: client)
        guard isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence) else {
          return false
        }
      } catch {
        guard isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence) else {
          return false
        }
        let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
        HarnessMonitorLogger.store.error(
          "task-board database capability check failed: \(description, privacy: .public)"
        )
        return false
      }
    }
    guard isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence) else {
      return false
    }
    var resolvedMigrationSource = false
    if let previousID = taskBoardSecretMigrationSource(for: capabilities.instanceID) {
      resolvedMigrationSource = await migrateStoredTaskBoardSecrets(
        from: previousID,
        to: capabilities.instanceID,
        containmentFence: fence,
        connectionFence: connectionFence
      )
      guard isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence) else {
        return false
      }
    }
    let synchronized = await syncStoredTaskBoardCredentials(
      using: client,
      instanceID: capabilities.instanceID,
      forceCredentialSync: true,
      containmentFence: fence,
      connectionFence: connectionFence
    )
    guard
      synchronized,
      isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence)
    else {
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
    containmentFence providedFence: LegacyContainmentFence? = nil,
    connectionFence: ConnectionAttemptFence? = nil
  ) async -> Bool {
    guard
      let fence = resolvedLegacyContainmentFence(
        providedFence ?? connectionFence?.containment
      ),
      isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence)
    else {
      return false
    }
    _ = await taskBoardSettingsWorker.completeRuntimeSecretHandoffIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: ownership
    )
    return isCurrentTaskBoardConnectionFence(fence, connectionFence: connectionFence)
  }

  func isCurrentTaskBoardConnectionFence(
    _ containmentFence: LegacyContainmentFence,
    connectionFence: ConnectionAttemptFence?
  ) -> Bool {
    guard isCurrentLegacyContainmentFence(containmentFence) else { return false }
    guard let connectionFence else { return true }
    return isCurrentConnectionAttemptFence(connectionFence)
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
