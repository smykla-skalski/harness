import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board settings save ordering")
struct HarnessMonitorStoreTaskBoardSettingsTests {
  @Test("Non-database Task Board capability is rejected")
  func rejectsFileBackedTaskBoardCapability() async {
    let client = RecordingHarnessClient()
    client.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "files",
      revision: 1,
      instanceID: "legacy-files"
    )
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    do {
      _ = try await store.requireDatabaseBackedTaskBoard(using: client)
      Issue.record("Expected file-backed Task Board rejection")
    } catch {
      #expect(store.taskBoardDatabaseInstanceID == nil)
    }

    await store.connect(using: client)

    #expect(store.client == nil)
    #expect(client.readCallCount(.taskBoardItems(nil)) == 0)
    #expect(client.readCallCount(.taskBoardOrchestratorStatus) == 0)
    #expect(client.recordedCalls().isEmpty)
  }

  @Test("Runtime config failure after orchestrator success surfaces partial save")
  func runtimeConfigFailureAfterOrchestratorSuccessSurfacesPartialSave() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardRuntimeConfigError(
      HarnessMonitorAPIError.server(code: 500, message: "Runtime config write failed.")
    )
    let store = await makeBootstrappedStore(client: client)
    let baselineCallCount = client.recordedCalls().count
    let snapshot = makeSettingsSnapshot()

    let success = await store.updateTaskBoardGitSettings(
      snapshot: snapshot,
      origin: .settingsSecretsSaveButton
    )

    #expect(success == false)
    let newCalls = Array(client.recordedCalls().dropFirst(baselineCallCount))
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardOrchestratorSettings = call { return true }
        return false
      }
    )
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardGitRuntimeConfig = call { return true }
        return false
      }
    )
    #expect(
      newCalls.contains { call in
        if case .syncTaskBoardGitHubTokens = call { return true }
        return false
      } == false
    )
    #expect(
      newCalls.contains { call in
        if case .syncTaskBoardTodoistToken = call { return true }
        return false
      } == false
    )
    let failureMessage = store.currentFailureFeedbackMessage ?? ""
    #expect(failureMessage.contains("Partial save"))
    #expect(failureMessage.contains("runtime config did not"))
  }

  @Test("Orchestrator failure bails before runtime config attempt")
  func orchestratorFailureBailsBeforeRuntimeConfig() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardOrchestratorSettingsError(
      HarnessMonitorAPIError.server(code: 502, message: "Orchestrator settings rejected.")
    )
    let store = await makeBootstrappedStore(client: client)
    let baselineCallCount = client.recordedCalls().count
    let snapshot = makeSettingsSnapshot()

    let success = await store.updateTaskBoardGitSettings(
      snapshot: snapshot,
      origin: .settingsSecretsSaveButton
    )

    #expect(success == false)
    let newCalls = Array(client.recordedCalls().dropFirst(baselineCallCount))
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardOrchestratorSettings = call { return true }
        return false
      }
    )
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardGitRuntimeConfig = call { return true }
        return false
      } == false
    )
    #expect(
      newCalls.contains { call in
        if case .syncTaskBoardGitHubTokens = call { return true }
        return false
      } == false
    )
  }

  @Test("Token sync failure runs after runtime success but leaves keychain unchanged")
  func tokenSyncFailureRunsAfterRuntimeSuccessButLeavesKeychainUnchanged() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardGitHubTokensSyncError(
      HarnessMonitorAPIError.server(code: 503, message: "Token sync unavailable.")
    )
    let store = await makeBootstrappedStore(client: client)
    let baselineCallCount = client.recordedCalls().count
    let snapshot = makeSettingsSnapshot()

    let success = await store.updateTaskBoardGitSettings(
      snapshot: snapshot,
      origin: .settingsSecretsSaveButton
    )

    #expect(success == false)
    let newCalls = Array(client.recordedCalls().dropFirst(baselineCallCount))
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardOrchestratorSettings = call { return true }
        return false
      }
    )
    #expect(
      newCalls.contains { call in
        if case .updateTaskBoardGitRuntimeConfig = call { return true }
        return false
      }
    )
    #expect(
      newCalls.contains { call in
        if case .syncTaskBoardGitHubTokens = call { return true }
        return false
      }
    )
    let failureMessage = store.currentFailureFeedbackMessage ?? ""
    #expect(failureMessage.contains("Partial save"))
    #expect(failureMessage.contains("token sync did not"))
    #expect(failureMessage.contains("keychain left unchanged"))
  }

  @Test("Successful save does not run external sync on the foreground path")
  func successfulSaveDoesNotRunExternalSyncOnForegroundPath() async {
    let client = RecordingHarnessClient()
    let credentialPersistence = InMemoryTaskBoardCredentialBundle()
    let keychainBundle = InMemoryTaskBoardKeychainBundle()
    let store = await makeBootstrappedStore(
      client: client,
      credentialPersistence: credentialPersistence,
      keychainBundle: keychainBundle
    )
    let baselineCallCount = client.recordedCalls().count
    let snapshot = makeSettingsSnapshot()

    let success = await store.updateTaskBoardGitSettings(
      snapshot: snapshot,
      origin: .settingsSecretsSaveButton
    )

    #expect(success)
    let newCalls = Array(client.recordedCalls().dropFirst(baselineCallCount))
    #expect(
      newCalls.contains { call in
        if case .syncTaskBoard = call { return true }
        return false
      } == false
    )
    #expect(store.currentSuccessFeedbackMessage == "Saved task board settings")
    #expect(credentialPersistence.github.savedSnapshots == [snapshot.githubCredentials])
    #expect(keychainBundle.ssh.recorded.isEmpty)
  }

  @Test("Repeated stored credential sync is skipped after bootstrap")
  func repeatedStoredCredentialSyncIsSkippedAfterBootstrap() async throws {
    let client = RecordingHarnessClient()
    let credentialPersistence = InMemoryTaskBoardCredentialBundle()
    try credentialPersistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "stored-github-token")
    )
    try credentialPersistence.todoist.save(
      TaskBoardTodoistCredentialSnapshot(token: "stored-todoist-token")
    )
    try credentialPersistence.openRouter.save(
      TaskBoardOpenRouterCredentialSnapshot(token: "stored-openrouter-token")
    )
    let store = await makeBootstrappedStore(
      client: client,
      credentialPersistence: credentialPersistence
    )

    await store.syncStoredTaskBoardCredentials(using: client)
    await store.syncStoredTaskBoardCredentials(using: client)

    let syncCalls = client.recordedCalls().filter { call in
      switch call {
      case .syncTaskBoardGitHubTokens, .syncTaskBoardTodoistToken,
        .syncTaskBoardOpenRouterToken:
        return true
      default:
        return false
      }
    }
    #expect(syncCalls.isEmpty)
  }

  @Test("A replacement daemon receives process-only credentials immediately")
  func replacementDaemonBypassesCredentialSyncDedupe() async throws {
    let initialClient = RecordingHarnessClient()
    let credentialPersistence = InMemoryTaskBoardCredentialBundle()
    try credentialPersistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "stored-github-token")
    )
    try credentialPersistence.todoist.save(
      TaskBoardTodoistCredentialSnapshot(token: "stored-todoist-token")
    )
    try credentialPersistence.openRouter.save(
      TaskBoardOpenRouterCredentialSnapshot(token: "stored-openrouter-token")
    )
    let store = await makeBootstrappedStore(
      client: initialClient,
      credentialPersistence: credentialPersistence
    )
    let replacementClient = RecordingHarnessClient()

    _ = await store.syncStoredTaskBoardCredentialsForNewDaemon(using: replacementClient)
    await store.syncStoredTaskBoardCredentials(using: replacementClient)

    let syncCalls = replacementClient.recordedCalls().filter { call in
      switch call {
      case .syncTaskBoardGitHubTokens, .syncTaskBoardTodoistToken,
        .syncTaskBoardOpenRouterToken:
        return true
      default:
        return false
      }
    }
    #expect(syncCalls.count == 3)
  }

  @Test("Stored service credentials are isolated by database identity")
  func storedServiceCredentialsAreDatabaseIsolated() async throws {
    let persistence = InMemoryTaskBoardCredentialBundle()
    try persistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "database-one-token"),
      scope: .database("database-one")
    )
    let worker = TaskBoardSettingsWorker(credentialPersistence: persistence.persistence)

    let first = try await worker.loadStoredCredentials(
      instanceID: "database-one",
      ownership: .external
    )
    let second = try await worker.loadStoredCredentials(
      instanceID: "database-two",
      ownership: .external
    )

    #expect(first.githubCredentials.globalToken == "database-one-token")
    #expect(second.isEmpty)
  }

  @Test("Managed legacy service credentials move once and cannot reappear after clearing")
  func managedLegacyServiceCredentialsMoveThenClear() async throws {
    let persistence = InMemoryTaskBoardCredentialBundle()
    try persistence.github.save(TaskBoardGitHubCredentialSnapshot(globalToken: "legacy-github"))
    try persistence.todoist.save(TaskBoardTodoistCredentialSnapshot(token: "legacy-todoist"))
    try persistence.openRouter.save(
      TaskBoardOpenRouterCredentialSnapshot(token: "legacy-openrouter")
    )
    let worker = TaskBoardSettingsWorker(credentialPersistence: persistence.persistence)

    let migrated = try await worker.loadStoredCredentials(
      instanceID: "database-one",
      ownership: .managed
    )
    #expect(migrated.githubCredentials.globalToken == "legacy-github")
    #expect(migrated.todoistCredentials.token == "legacy-todoist")
    #expect(migrated.openRouterCredentials.token == "legacy-openrouter")
    #expect(try persistence.github.load().isEmpty)
    #expect(try persistence.todoist.load().isEmpty)
    #expect(try persistence.openRouter.load().isEmpty)

    let baseline = makeSettingsSnapshot()
    let cleared = TaskBoardGitSettingsSnapshot(
      orchestratorSettings: baseline.orchestratorSettings,
      runtimeConfig: baseline.runtimeConfig,
      githubCredentials: TaskBoardGitHubCredentialSnapshot()
    )
    try await worker.persistLocalSecrets(
      snapshot: cleared,
      origin: .settingsSecretsSaveButton,
      instanceID: "database-one",
      ownership: .managed
    )
    let reloaded = try await worker.loadStoredCredentials(
      instanceID: "database-one",
      ownership: .managed
    )
    #expect(reloaded.isEmpty)
  }

  private func makeSettingsSnapshot() -> TaskBoardGitSettingsSnapshot {
    TaskBoardGitSettingsSnapshot(
      orchestratorSettings: TaskBoardOrchestratorSettings(
        enabledWorkflows: [.defaultTask],
        dryRunDefault: true,
        dispatchStatusFilter: .todo,
        projectDir: nil,
        githubProject: TaskBoardGitHubProjectConfig(
          owner: "example",
          repo: "harness",
          checkoutPath: "",
          defaultBranch: "main",
          branchPrefix: "c/"
        ),
        githubInbox: TaskBoardGitHubInboxConfig(),
        policyVersion: "task-board-policy-v1"
      ),
      runtimeConfig: TaskBoardGitRuntimeConfig(
        global: TaskBoardGitRuntimeProfile(),
        repositoryOverrides: []
      ),
      githubCredentials: TaskBoardGitHubCredentialSnapshot(
        globalToken: "new-token",
        repositoryTokens: []
      ),
      todoistCredentials: TaskBoardTodoistCredentialSnapshot(token: nil)
    )
  }
}
