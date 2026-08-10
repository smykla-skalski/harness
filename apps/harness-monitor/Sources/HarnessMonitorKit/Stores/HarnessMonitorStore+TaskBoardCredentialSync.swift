import Foundation

private let taskBoardCredentialSyncRepeatInterval: TimeInterval = 30 * 60

extension HarnessMonitorStore {
  @discardableResult
  func syncStoredTaskBoardCredentials(
    using client: any HarnessMonitorClientProtocol,
    instanceID providedInstanceID: String? = nil,
    forceCredentialSync: Bool = false,
    accessFence providedFence: TaskBoardAccessFence? = nil
  ) async -> Bool {
    guard let fence = resolvedTaskBoardAccessFence(providedFence) else {
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
        accessFence: fence
      )
    else {
      return false
    }
    return await pushStoredTaskBoardCredentials(
      using: client,
      instanceID: instanceID,
      forceCredentialSync: forceCredentialSync,
      accessFence: fence
    )
  }

  private func pushStoredTaskBoardCredentials(
    using client: any HarnessMonitorClientProtocol,
    instanceID: String,
    forceCredentialSync: Bool,
    accessFence: TaskBoardAccessFence
  ) async -> Bool {
    do {
      async let storedCredentials = taskBoardSettingsWorker.loadStoredCredentials(
        instanceID: instanceID,
        ownership: daemonOwnership
      )
      async let runtimeConfig = client.taskBoardGitRuntimeConfig()
      let baseRuntime = try await runtimeConfig
      guard
        isCurrentTaskBoardAccessFence(accessFence)
      else {
        return false
      }
      recordTaskBoardRepositoryOverrides(instanceID: instanceID, runtime: baseRuntime)
      let hydratedRuntime = await taskBoardSettingsWorker.hydrateKeyMaterial(
        into: baseRuntime,
        instanceID: instanceID,
        ownership: daemonOwnership
      )
      guard
        isCurrentTaskBoardAccessFence(accessFence)
      else {
        return false
      }
      _ = try await client.syncTaskBoardGitRuntimeKeyMaterial(
        request: TaskBoardGitRuntimeKeyMaterialSyncRequest(runtime: hydratedRuntime)
      )
      guard
        isCurrentTaskBoardAccessFence(accessFence)
      else {
        return false
      }
      let credentials = try await storedCredentials
      guard
        isCurrentTaskBoardAccessFence(accessFence)
      else {
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
      guard
        isCurrentTaskBoardAccessFence(accessFence)
      else {
        return false
      }
      _ = try await client.syncTaskBoardOpenRouterToken(
        request: credentials.openRouterCredentials.syncRequest
      )
      guard
        isCurrentTaskBoardAccessFence(accessFence)
      else {
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
      return false
    }
    return isCurrentTaskBoardAccessFence(accessFence)
  }

  func syncStoredTaskBoardCredentialsForNewDaemon(
    using client: any HarnessMonitorClientProtocol,
    validatedCapabilities: TaskBoardCapabilities? = nil,
    accessFence providedFence: TaskBoardAccessFence? = nil
  ) async -> Bool {
    guard let fence = resolvedTaskBoardAccessFence(providedFence) else {
      return false
    }
    let capabilities: TaskBoardCapabilities
    if let validatedCapabilities {
      capabilities = validatedCapabilities
    } else {
      do {
        capabilities = try await databaseBackedTaskBoardCapabilities(using: client)
        guard
          isCurrentTaskBoardAccessFence(fence)
        else {
          return false
        }
      } catch {
        guard
          isCurrentTaskBoardAccessFence(fence)
        else {
          return false
        }
        let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
        HarnessMonitorLogger.store.error(
          "task-board database capability check failed: \(description, privacy: .public)"
        )
        return false
      }
    }
    guard
      isCurrentTaskBoardAccessFence(fence)
    else {
      return false
    }
    var resolvedMigrationSource = false
    if let previousID = taskBoardSecretMigrationSource(for: capabilities.instanceID) {
      resolvedMigrationSource = await migrateStoredTaskBoardSecrets(
        from: previousID,
        to: capabilities.instanceID,
        accessFence: fence
      )
      guard
        isCurrentTaskBoardAccessFence(fence)
      else {
        return false
      }
    }
    let synchronized = await syncStoredTaskBoardCredentials(
      using: client,
      instanceID: capabilities.instanceID,
      forceCredentialSync: true,
      accessFence: fence
    )
    guard
      synchronized,
      isCurrentTaskBoardAccessFence(fence)
    else {
      return false
    }
    adoptDatabaseBackedTaskBoard(capabilities)
    if resolvedMigrationSource {
      taskBoardRuntimeState.connection.previousDatabaseInstanceID = nil
    }
    return true
  }

  private func resolvedTaskBoardAccessFence(
    _ providedFence: TaskBoardAccessFence?
  ) -> TaskBoardAccessFence? {
    if let providedFence {
      return isCurrentTaskBoardAccessFence(providedFence) ? providedFence : nil
    }
    guard let containment = try? currentLegacyContainmentFence() else { return nil }
    return TaskBoardAccessFence(
      containment: containment,
      connection: nil,
      databaseAccessGeneration: nil
    )
  }

  func migrateRuntimeSecretsUsingWorkerIfNeeded(
    client: any HarnessMonitorClientProtocol,
    instanceID: String,
    ownership: DaemonOwnership,
    accessFence providedFence: TaskBoardAccessFence? = nil
  ) async -> Bool {
    guard let fence = resolvedTaskBoardAccessFence(providedFence) else {
      return false
    }
    let completed = await taskBoardSettingsWorker.completeRuntimeSecretHandoffIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: ownership
    )
    return completed && isCurrentTaskBoardAccessFence(fence)
  }

  func isCurrentTaskBoardAccessFence(_ fence: TaskBoardAccessFence) -> Bool {
    guard isCurrentLegacyContainmentFence(fence.containment) else { return false }
    if let connection = fence.connection, !isCurrentConnectionAttemptFence(connection) {
      return false
    }
    if let databaseAccessGeneration = fence.databaseAccessGeneration,
      !isCurrentTaskBoardDatabaseAccessGeneration(databaseAccessGeneration)
    {
      return false
    }
    return true
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
