import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor cross-daemon secret migration")
struct HarnessMonitorStoreSecretMigrationTests {
  @Test("A replacement daemon after app relaunch reviews and carries stored secrets")
  func replacementDaemonAfterRelaunchMigratesSecrets() async throws {
    let suiteName = "HarnessMonitorStoreSecretMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let connectionHistory = TaskBoardConnectionHistoryStore(defaults: defaults)
    let credentials = InMemoryTaskBoardCredentialBundle()
    let keyMaterial = InMemoryTaskBoardKeychainBundle()
    try credentials.github.save(
      TaskBoardGitHubCredentialSnapshot(
        repositoryTokens: [
          TaskBoardGitHubRepositoryToken(repository: "org/repo", token: "repo-token-A")
        ]
      ),
      scope: .database("daemon-A")
    )
    let initialClient = RecordingHarnessClient()
    initialClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 1,
      instanceID: "daemon-A"
    )
    _ = await makeBootstrappedStore(
      client: initialClient,
      credentialPersistence: credentials,
      keychainBundle: keyMaterial,
      taskBoardConnectionHistoryStore: connectionHistory
    )

    let replacementClient = RecordingHarnessClient()
    replacementClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 2,
      instanceID: "daemon-B"
    )
    let replacementWorker = TaskBoardSettingsWorker(
      credentialPersistence: credentials.persistence,
      keyMaterialPersistence: keyMaterial.persistence
    )
    let relaunchedStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: replacementClient),
      voiceCapture: NativeVoiceCaptureService(),
      taskBoardSettingsWorker: replacementWorker,
      taskBoardConnectionHistoryStore: TaskBoardConnectionHistoryStore(defaults: defaults)
    )

    async let bootstrapped: Void = relaunchedStore.bootstrap()
    #expect(await waitUntil { relaunchedStore.presentedSheet != nil })
    relaunchedStore.resolveSecretMigrationConsent([.repositoryGitHubToken("org/repo"): true])
    await bootstrapped

    let migrated = try credentials.github.load(scope: .database("daemon-B"))
    #expect(migrated.repositoryTokens.first?.repository == "org/repo")
    #expect(migrated.repositoryTokens.first?.token == "repo-token-A")
    #expect(relaunchedStore.presentedSheet == nil)
  }

  @Test("Repository override history survives app relaunch")
  func repositoryOverrideHistorySurvivesRelaunch() throws {
    let suiteName = "HarnessMonitorStoreSecretMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let connectionHistory = TaskBoardConnectionHistoryStore(defaults: defaults)
    connectionHistory.recordRepositoryOverrideSlugs(["org/repo"], instanceID: "daemon-A")
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      voiceCapture: NativeVoiceCaptureService(),
      taskBoardSettingsWorker: TaskBoardSettingsWorker(
        credentialPersistence: InMemoryTaskBoardCredentialBundle().persistence,
        keyMaterialPersistence: InMemoryTaskBoardKeychainBundle().persistence
      ),
      taskBoardConnectionHistoryStore: TaskBoardConnectionHistoryStore(defaults: defaults)
    )

    #expect(store.knownTaskBoardRepositorySlugs(for: "daemon-A") == ["org/repo"])
  }

  @Test("Connecting to a replacement daemon reviews and carries stored secrets")
  func connectingToReplacementDaemonMigratesSecrets() async throws {
    let initialClient = RecordingHarnessClient()
    initialClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 1,
      instanceID: "daemon-A"
    )
    let credentialPersistence = InMemoryTaskBoardCredentialBundle()
    let keychainBundle = InMemoryTaskBoardKeychainBundle()
    try credentialPersistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "gh-token-A"),
      scope: .database("daemon-A")
    )
    try credentialPersistence.openRouter.save(
      TaskBoardOpenRouterCredentialSnapshot(token: "or-token-A"),
      scope: .database("daemon-A")
    )
    try keychainBundle.ssh.save(
      TaskBoardKeyMaterialSnapshot(privateKey: "ssh-key-A"),
      scope: .databaseGlobal("daemon-A")
    )
    try keychainBundle.gpg.save(
      TaskBoardKeyMaterialSnapshot(privateKey: "gpg-key-A"),
      scope: .databaseGlobal("daemon-A")
    )
    let store = await makeBootstrappedStore(
      client: initialClient,
      credentialPersistence: credentialPersistence,
      keychainBundle: keychainBundle
    )

    let replacementClient = RecordingHarnessClient()
    replacementClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 2,
      instanceID: "daemon-B"
    )

    // The replacement daemon holds nothing, so every secret is an on-by-default
    // carry-over. The sheet still appears on the real switch path (connect()
    // runs the capability check twice); applying it carries everything over.
    async let connected: Void = store.connect(using: replacementClient)
    #expect(await waitUntil { store.presentedSheet != nil })
    store.resolveSecretMigrationConsent([
      .githubGlobalToken: true,
      .openRouterToken: true,
      .sshKey: true,
      .gpgKey: true,
    ])
    await connected

    let migratedGithub = try credentialPersistence.github.load(scope: .database("daemon-B"))
    #expect(migratedGithub.globalToken == "gh-token-A")
    let migratedOpenRouter = try credentialPersistence.openRouter.load(scope: .database("daemon-B"))
    #expect(migratedOpenRouter.token == "or-token-A")
    let migratedSSH = try keychainBundle.ssh.load(scope: .databaseGlobal("daemon-B"))
    #expect(migratedSSH.privateKey == "ssh-key-A")
    let migratedGPG = try keychainBundle.gpg.load(scope: .databaseGlobal("daemon-B"))
    #expect(migratedGPG.privateKey == "gpg-key-A")
    #expect(store.presentedSheet == nil)
  }

  @Test("Migration carries per-repo key material for overrides without a GitHub token")
  func migrationCarriesRepoOverrideKeyMaterial() async throws {
    let keychainBundle = InMemoryTaskBoardKeychainBundle()
    try keychainBundle.signingSsh.save(
      TaskBoardKeyMaterialSnapshot(privateKey: "repo-signing-A"),
      scope: .databaseRepository("daemon-A", "org/repo-x")
    )
    let worker = TaskBoardSettingsWorker(
      credentialPersistence: InMemoryTaskBoardCredentialBundle().persistence,
      keyMaterialPersistence: keychainBundle.persistence
    )

    try await worker.migrateStoredSecrets(
      from: "daemon-A",
      to: "daemon-B",
      knownRepositories: ["org/repo-x"],
      selections: [.repositorySigningSSHKey("org/repo-x"): true]
    )

    #expect(
      try keychainBundle.signingSsh.load(scope: .databaseRepository("daemon-B", "org/repo-x"))
        .privateKey == "repo-signing-A"
    )
  }

  @Test("Scan flags clashing secrets as conflicts and the rest as carry-overs")
  func scanClassifiesConflictsAndCarryOvers() async throws {
    let credentialPersistence = InMemoryTaskBoardCredentialBundle()
    let keychainBundle = InMemoryTaskBoardKeychainBundle()
    try credentialPersistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "gh-A"),
      scope: .database("daemon-A")
    )
    try credentialPersistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "gh-B"),
      scope: .database("daemon-B")
    )
    try keychainBundle.ssh.save(
      TaskBoardKeyMaterialSnapshot(privateKey: "ssh-A"),
      scope: .databaseGlobal("daemon-A")
    )
    try keychainBundle.ssh.save(
      TaskBoardKeyMaterialSnapshot(privateKey: "ssh-B"),
      scope: .databaseGlobal("daemon-B")
    )
    // OpenRouter only on the old daemon, so it is a carry-over, not a conflict.
    try credentialPersistence.openRouter.save(
      TaskBoardOpenRouterCredentialSnapshot(token: "or-A"),
      scope: .database("daemon-A")
    )
    let worker = TaskBoardSettingsWorker(
      credentialPersistence: credentialPersistence.persistence,
      keyMaterialPersistence: keychainBundle.persistence
    )

    let items = try await worker.secretMigrationItems(
      from: "daemon-A",
      to: "daemon-B",
      knownRepositories: []
    )

    let conflicts = Set(items.filter { $0.disposition == .conflict }.map(\.kind))
    let carryOvers = Set(items.filter { $0.disposition == .carryOver }.map(\.kind))
    #expect(conflicts == [.githubGlobalToken, .sshKey])
    #expect(carryOvers == [.openRouterToken])
  }

  @Test("Migration honors per-secret selections")
  func migrationHonorsPerSecretSelections() async throws {
    let credentialPersistence = InMemoryTaskBoardCredentialBundle()
    let keychainBundle = InMemoryTaskBoardKeychainBundle()
    try credentialPersistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "gh-A"),
      scope: .database("daemon-A")
    )
    try credentialPersistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "gh-B"),
      scope: .database("daemon-B")
    )
    try keychainBundle.ssh.save(
      TaskBoardKeyMaterialSnapshot(privateKey: "ssh-A", passphrase: "pass-A"),
      scope: .databaseGlobal("daemon-A")
    )
    try keychainBundle.ssh.save(
      TaskBoardKeyMaterialSnapshot(privateKey: "ssh-B"),
      scope: .databaseGlobal("daemon-B")
    )
    let worker = TaskBoardSettingsWorker(
      credentialPersistence: credentialPersistence.persistence,
      keyMaterialPersistence: keychainBundle.persistence
    )

    // Keep the new daemon's GitHub token, replace its SSH key with the old one.
    try await worker.migrateStoredSecrets(
      from: "daemon-A",
      to: "daemon-B",
      knownRepositories: [],
      selections: [.githubGlobalToken: false, .sshKey: true]
    )

    let migratedGithub = try credentialPersistence.github.load(scope: .database("daemon-B"))
    #expect(migratedGithub.globalToken == "gh-B")
    let migratedSSH = try keychainBundle.ssh.load(scope: .databaseGlobal("daemon-B"))
    #expect(migratedSSH.privateKey == "ssh-A")
    #expect(migratedSSH.passphrase == "pass-A")
  }

  @Test("Connecting with a conflict prompts and applies the chosen value")
  func connectingWithConflictPromptsAndApplies() async throws {
    let initialClient = RecordingHarnessClient()
    initialClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 1,
      instanceID: "daemon-A"
    )
    let credentialPersistence = InMemoryTaskBoardCredentialBundle()
    let keychainBundle = InMemoryTaskBoardKeychainBundle()
    try credentialPersistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "gh-token-A"),
      scope: .database("daemon-A")
    )
    let store = await makeBootstrappedStore(
      client: initialClient,
      credentialPersistence: credentialPersistence,
      keychainBundle: keychainBundle
    )
    // The new daemon already carries a clashing global token.
    try credentialPersistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "gh-token-B"),
      scope: .database("daemon-B")
    )

    let replacementClient = RecordingHarnessClient()
    replacementClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 2,
      instanceID: "daemon-B"
    )

    async let connected: Void = store.connect(using: replacementClient)
    #expect(await waitUntil { store.presentedSheet != nil })
    // Replace = carry the previous daemon's value over.
    store.resolveSecretMigrationConsent([.githubGlobalToken: true])
    await connected

    let migratedGithub = try credentialPersistence.github.load(scope: .database("daemon-B"))
    #expect(migratedGithub.globalToken == "gh-token-A")
    #expect(store.presentedSheet == nil)
  }

  @Test("Cancelling the review carries nothing and does not prompt again")
  func cancellingReviewCarriesNothing() async throws {
    let initialClient = RecordingHarnessClient()
    initialClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 1,
      instanceID: "daemon-A"
    )
    let credentialPersistence = InMemoryTaskBoardCredentialBundle()
    let keychainBundle = InMemoryTaskBoardKeychainBundle()
    try credentialPersistence.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "gh-token-A"),
      scope: .database("daemon-A")
    )
    let store = await makeBootstrappedStore(
      client: initialClient,
      credentialPersistence: credentialPersistence,
      keychainBundle: keychainBundle
    )

    let replacementClient = RecordingHarnessClient()
    replacementClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 2,
      instanceID: "daemon-B"
    )

    async let connected: Void = store.connect(using: replacementClient)
    #expect(await waitUntil { store.presentedSheet != nil })
    store.resolveSecretMigrationConsent(nil)
    await connected

    let daemonB = try credentialPersistence.github.load(scope: .database("daemon-B"))
    #expect(daemonB.globalToken == nil)
    // Cleared, so a later reconnect to the same daemon does not prompt again.
    #expect(store.taskBoardPreviousDatabaseInstanceID == nil)
    #expect(store.presentedSheet == nil)
  }

  @Test("Consent resolution resumes the parked review decision")
  func consentResolutionResumesDecision() async {
    let store = await makeBootstrappedStore()
    let items = [TaskBoardSecretMigrationItem(kind: .githubGlobalToken, disposition: .conflict)]

    async let decision = store.presentSecretMigrationConsent(items)
    #expect(await waitUntil { store.presentedSheet != nil })
    store.resolveSecretMigrationConsent([.githubGlobalToken: true])
    let resolved = await decision

    #expect(resolved == [.githubGlobalToken: true])
    #expect(store.presentedSheet == nil)
  }

  @Test("Dismissing the review sheet resumes without a choice")
  func dismissingConsentResumesWithoutChoice() async {
    let store = await makeBootstrappedStore()

    async let decision = store.presentSecretMigrationConsent([
      TaskBoardSecretMigrationItem(kind: .sshKey, disposition: .conflict)
    ])
    #expect(await waitUntil { store.presentedSheet != nil })
    store.dismissSheet()
    let resolved = await decision

    #expect(resolved == nil)
    #expect(store.presentedSheet == nil)
  }
}
