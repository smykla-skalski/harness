import Foundation

extension HarnessMonitorStore {
  func requireDatabaseBackedTaskBoard(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> TaskBoardCapabilities {
    taskBoardDatabaseInstanceID = nil
    let capabilities: TaskBoardCapabilities
    do {
      capabilities = try await client.taskBoardCapabilities()
    } catch {
      taskBoardDatabaseInstanceID = nil
      throw error
    }
    guard capabilities.storage == "database" else {
      throw HarnessMonitorAPIError.server(
        code: 426,
        message: "Connected daemon does not provide a database-backed Task Board"
      )
    }
    guard !capabilities.instanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw HarnessMonitorAPIError.server(
        code: 500,
        message: "Database-backed Task Board did not provide an instance identity"
      )
    }
    taskBoardDatabaseInstanceID = capabilities.instanceID
    contentUI.dashboard.taskBoardRevision = capabilities.revision
    return capabilities
  }

  nonisolated static func hydrateKeyMaterial(
    into runtime: TaskBoardGitRuntimeConfig,
    instanceID: String,
    ownership: DaemonOwnership,
    keychain: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) -> TaskBoardGitRuntimeConfig {
    TaskBoardGitRuntimeConfig(
      global: hydrateProfile(
        runtime.global,
        scope: .databaseGlobal(instanceID),
        legacyScope: ownership == .managed ? .global : nil,
        keychain: keychain
      ),
      repositoryOverrides: runtime.repositoryOverrides.map { override in
        TaskBoardGitRepositoryOverride(
          repository: override.repository,
          profile: hydrateProfile(
            override.profile,
            scope: .databaseRepository(instanceID, override.repository),
            legacyScope: ownership == .managed ? .repository(override.repository) : nil,
            keychain: keychain
          )
        )
      }
    )
  }

  nonisolated static func persistKeyMaterial(
    runtime: TaskBoardGitRuntimeConfig,
    instanceID: String,
    ownership: DaemonOwnership,
    keychain: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) throws {
    try persistProfileKeyMaterial(
      runtime.global,
      scope: .databaseGlobal(instanceID),
      legacyScope: ownership == .managed ? .global : nil,
      keychain: keychain
    )
    for override in runtime.repositoryOverrides {
      try persistProfileKeyMaterial(
        override.profile,
        scope: .databaseRepository(instanceID, override.repository),
        legacyScope: ownership == .managed ? .repository(override.repository) : nil,
        keychain: keychain
      )
    }
  }

  nonisolated static func verifyPersistedKeyMaterial(
    runtime: TaskBoardGitRuntimeConfig,
    instanceID: String,
    keychain: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) throws {
    try verifyProfileKeyMaterial(
      runtime.global,
      scope: .databaseGlobal(instanceID),
      keychain: keychain
    )
    for override in runtime.repositoryOverrides {
      try verifyProfileKeyMaterial(
        override.profile,
        scope: .databaseRepository(instanceID, override.repository),
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
    instanceID: String,
    ownership: DaemonOwnership,
    keychain: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) async -> Bool {
    await completeRuntimeSecretHandoffIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: ownership,
      keychain: keychain
    )
  }

  nonisolated static func completeRuntimeSecretHandoffIfNeeded(
    client: any HarnessMonitorClientProtocol,
    instanceID: String,
    ownership: DaemonOwnership,
    keychain: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) async -> Bool {
    do {
      let response = try await client.prepareTaskBoardGitRuntimeSecretHandoff()
      guard response.prepared else {
        return true
      }
      guard let migrationID = response.migrationID, let digest = response.digest else {
        return false
      }
      try persistKeyMaterial(
        runtime: response.runtime,
        instanceID: instanceID,
        ownership: ownership,
        keychain: keychain
      )
      try verifyPersistedKeyMaterial(
        runtime: response.runtime,
        instanceID: instanceID,
        keychain: keychain
      )
      let acknowledgement = try await client.acknowledgeTaskBoardGitRuntimeSecretHandoff(
        request: TaskBoardGitRuntimeSecretHandoffAckRequest(
          migrationID: migrationID,
          digest: digest
        )
      )
      return acknowledgement.acknowledged
    } catch {
      // The daemon remains authoritative; the next connection retries safely.
      return false
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
    legacyScope: TaskBoardKeyMaterialStore.Scope?,
    keychain: TaskBoardKeyMaterialPersistence
  ) -> TaskBoardGitRuntimeProfile {
    let ssh = loadKeyMaterial(keychain.ssh, scope: scope, legacyScope: legacyScope)
    let signingSsh = loadKeyMaterial(
      keychain.signingSsh,
      scope: scope,
      legacyScope: legacyScope
    )
    let gpg = loadKeyMaterial(keychain.gpg, scope: scope, legacyScope: legacyScope)

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
    legacyScope: TaskBoardKeyMaterialStore.Scope?,
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
    if let legacyScope {
      try keychain.ssh.delete(scope: legacyScope)
    }
    try keychain.signingSsh.save(
      TaskBoardKeyMaterialSnapshot(
        privateKey: profile.signing.sshPrivateKey,
        passphrase: profile.signing.sshPrivateKeyPassphrase,
        keyPath: profile.signing.sshKeyPath
      ),
      scope: scope
    )
    if let legacyScope {
      try keychain.signingSsh.delete(scope: legacyScope)
    }
    try keychain.gpg.save(
      TaskBoardKeyMaterialSnapshot(
        privateKey: profile.signing.gpgPrivateKey,
        passphrase: profile.signing.gpgPrivateKeyPassphrase,
        keyPath: profile.signing.gpgPrivateKeyPath,
        keyId: profile.signing.gpgKeyId
      ),
      scope: scope
    )
    if let legacyScope {
      try keychain.gpg.delete(scope: legacyScope)
    }
  }

  nonisolated private static func verifyProfileKeyMaterial(
    _ profile: TaskBoardGitRuntimeProfile,
    scope: TaskBoardKeyMaterialStore.Scope,
    keychain: TaskBoardKeyMaterialPersistence
  ) throws {
    let expectedSSH = TaskBoardKeyMaterialSnapshot(
      privateKey: profile.sshPrivateKey,
      passphrase: profile.sshPrivateKeyPassphrase,
      keyPath: profile.sshKeyPath
    )
    let expectedSigningSSH = TaskBoardKeyMaterialSnapshot(
      privateKey: profile.signing.sshPrivateKey,
      passphrase: profile.signing.sshPrivateKeyPassphrase,
      keyPath: profile.signing.sshKeyPath
    )
    let expectedGPG = TaskBoardKeyMaterialSnapshot(
      privateKey: profile.signing.gpgPrivateKey,
      passphrase: profile.signing.gpgPrivateKeyPassphrase,
      keyPath: profile.signing.gpgPrivateKeyPath,
      keyId: profile.signing.gpgKeyId
    )
    guard
      try keychain.ssh.load(scope: scope) == expectedSSH,
      try keychain.signingSsh.load(scope: scope) == expectedSigningSSH,
      try keychain.gpg.load(scope: scope) == expectedGPG
    else {
      throw TaskBoardKeyMaterialStoreError.invalidPayload
    }
  }

  nonisolated private static func loadKeyMaterial(
    _ persistence: any TaskBoardKeyMaterialPersisting,
    scope: TaskBoardKeyMaterialStore.Scope,
    legacyScope: TaskBoardKeyMaterialStore.Scope?
  ) -> TaskBoardKeyMaterialSnapshot {
    let owned = (try? persistence.load(scope: scope)) ?? TaskBoardKeyMaterialSnapshot()
    guard let legacyScope else {
      return owned
    }
    if !owned.isEmpty {
      try? persistence.delete(scope: legacyScope)
      return owned
    }
    let legacy = (try? persistence.load(scope: legacyScope)) ?? TaskBoardKeyMaterialSnapshot()
    if !legacy.isEmpty {
      do {
        try persistence.save(legacy, scope: scope)
        guard try persistence.load(scope: scope) == legacy else {
          return legacy
        }
        try persistence.delete(scope: legacyScope)
      } catch {
        return legacy
      }
    }
    return legacy
  }

}
