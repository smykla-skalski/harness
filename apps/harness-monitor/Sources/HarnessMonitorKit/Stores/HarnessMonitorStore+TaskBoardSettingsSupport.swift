import Foundation

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

  nonisolated static func fetchIdentityDefaults(
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

  static func orchestratorSettingsUpdateRequest(
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

  static func normalizedTaskBoardPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
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
}
