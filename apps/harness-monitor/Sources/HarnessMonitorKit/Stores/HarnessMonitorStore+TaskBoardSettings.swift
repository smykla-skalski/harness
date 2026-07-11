import Foundation

private let taskBoardCredentialSyncRepeatInterval: TimeInterval = 30 * 60

struct TaskBoardCredentialSyncState: Sendable {
  let credentials: TaskBoardStoredCredentialSnapshot
  let syncedAt: Date
}

extension HarnessMonitorStore {
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
      lastTaskBoardCredentialSync = TaskBoardCredentialSyncState(
        credentials: TaskBoardStoredCredentialSnapshot(
          githubCredentials: snapshot.githubCredentials,
          todoistCredentials: snapshot.todoistCredentials,
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
      let now = Date()
      if shouldSkipStoredTaskBoardCredentialSync(credentials, now: now) {
        return
      }
      _ = try await client.syncTaskBoardGitHubTokens(
        request: credentials.githubCredentials.syncRequest
      )
      _ = try await client.syncTaskBoardTodoistToken(
        request: credentials.todoistCredentials.syncRequest
      )
      _ = try await client.syncTaskBoardOpenRouterToken(
        request: credentials.openRouterCredentials.syncRequest
      )
      lastTaskBoardCredentialSync = TaskBoardCredentialSyncState(
        credentials: credentials,
        syncedAt: now
      )
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.error(
        "task-board credential sync failed: \(description, privacy: .public)"
      )
    }
  }

  private func shouldSkipStoredTaskBoardCredentialSync(
    _ credentials: TaskBoardStoredCredentialSnapshot,
    now: Date
  ) -> Bool {
    if credentials.isEmpty,
      lastTaskBoardCredentialSync?.credentials.isEmpty != false
    {
      lastTaskBoardCredentialSync = TaskBoardCredentialSyncState(
        credentials: credentials,
        syncedAt: now
      )
      return true
    }
    guard let lastTaskBoardCredentialSync else {
      return false
    }
    return lastTaskBoardCredentialSync.credentials == credentials
      && now.timeIntervalSince(lastTaskBoardCredentialSync.syncedAt)
        < taskBoardCredentialSyncRepeatInterval
  }

}
