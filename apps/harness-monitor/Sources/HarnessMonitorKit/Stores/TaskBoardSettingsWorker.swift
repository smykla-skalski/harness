import Foundation

struct TaskBoardStoredCredentialSnapshot: Equatable, Sendable {
  let githubCredentials: TaskBoardGitHubCredentialSnapshot
  let openRouterCredentials: TaskBoardOpenRouterCredentialSnapshot

  var isEmpty: Bool {
    githubCredentials.isEmpty && openRouterCredentials.isEmpty
  }
}

public enum TaskBoardSettingsSaveOrigin: String, Sendable {
  case settingsSecretsSaveButton
  case settingsRepositoriesSaveButton
}

protocol TaskBoardGitHubCredentialPersisting: Sendable {
  func load(scope: TaskBoardCredentialScope) throws -> TaskBoardGitHubCredentialSnapshot
  func save(_ snapshot: TaskBoardGitHubCredentialSnapshot, scope: TaskBoardCredentialScope) throws
  func delete(scope: TaskBoardCredentialScope) throws
}

protocol TaskBoardOpenRouterCredentialPersisting: Sendable {
  func load(scope: TaskBoardCredentialScope) throws -> TaskBoardOpenRouterCredentialSnapshot
  func save(
    _ snapshot: TaskBoardOpenRouterCredentialSnapshot,
    scope: TaskBoardCredentialScope
  ) throws
  func delete(scope: TaskBoardCredentialScope) throws
}

public enum TaskBoardCredentialScope: Hashable, Sendable {
  case legacy
  case database(String)

  var account: String {
    switch self {
    case .legacy:
      "default"
    case .database(let instanceID):
      TaskBoardKeyMaterialStore.Scope.databaseGlobal(instanceID).account
    }
  }
}

struct TaskBoardCredentialPersistence: Sendable {
  let github: any TaskBoardGitHubCredentialPersisting
  let openRouter: any TaskBoardOpenRouterCredentialPersisting
  let retiredTodoistPurge: TaskBoardTodoistCredentialPurge

  /// Real Keychain in normal runs; in-memory stand-ins under xctest so test
  /// processes never trigger the macOS Keychain access prompt.
  static var defaultKeychain: Self {
    if HarnessMonitorEnvironment.current.isXCTestProcess {
      return .inMemory
    }
    return Self(
      github: TaskBoardGitHubCredentialStore(),
      openRouter: TaskBoardOpenRouterCredentialStore(),
      retiredTodoistPurge: .keychain
    )
  }
}

private struct TaskBoardSecretHandoffOperation: Sendable {
  let id = UUID()
  let instanceID: String
  let task: Task<Bool, Never>
}

private struct TaskBoardCredentialLoadContext: Sendable {
  let scope: TaskBoardCredentialScope
  let migratesLegacy: Bool
}

actor TaskBoardSettingsWorker {
  private let credentialPersistence: TaskBoardCredentialPersistence
  private let keyMaterialPersistence: TaskBoardKeyMaterialPersistence
  private var secretHandoffOperation: TaskBoardSecretHandoffOperation?

  init(
    credentialPersistence: TaskBoardCredentialPersistence = .defaultKeychain,
    keyMaterialPersistence: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) {
    self.credentialPersistence = credentialPersistence
    self.keyMaterialPersistence = keyMaterialPersistence
  }

  func loadStoredCredentials(
    instanceID: String,
    ownership: DaemonOwnership
  ) throws -> TaskBoardStoredCredentialSnapshot {
    if credentialPersistence.retiredTodoistPurge.run() {
      HarnessMonitorLogger.store.info("removed the retired Todoist Keychain credential")
    }
    let context = TaskBoardCredentialLoadContext(
      scope: .database(instanceID),
      migratesLegacy: ownership == .managed
    )
    return try TaskBoardStoredCredentialSnapshot(
      githubCredentials: loadScopedCredential(
        context: context,
        empty: TaskBoardGitHubCredentialSnapshot(),
        load: credentialPersistence.github.load,
        save: credentialPersistence.github.save,
        delete: credentialPersistence.github.delete
      ),
      openRouterCredentials: loadScopedCredential(
        context: context,
        empty: TaskBoardOpenRouterCredentialSnapshot(),
        load: credentialPersistence.openRouter.load,
        save: credentialPersistence.openRouter.save,
        delete: credentialPersistence.openRouter.delete
      )
    )
  }

  func hydrateKeyMaterial(
    into runtime: TaskBoardGitRuntimeConfig,
    instanceID: String,
    ownership: DaemonOwnership
  ) -> TaskBoardGitRuntimeConfig {
    HarnessMonitorStore.hydrateKeyMaterial(
      into: runtime,
      instanceID: instanceID,
      ownership: ownership,
      keychain: keyMaterialPersistence
    )
  }

  func persistLocalSecrets(
    snapshot: TaskBoardGitSettingsSnapshot,
    origin: TaskBoardSettingsSaveOrigin,
    instanceID: String,
    ownership: DaemonOwnership
  ) async throws {
    while let operation = secretHandoffOperation {
      _ = await operation.task.value
      clearSecretHandoffOperation(id: operation.id)
    }
    switch origin {
    case .settingsSecretsSaveButton, .settingsRepositoriesSaveButton:
      break
    }
    let scope = TaskBoardCredentialScope.database(instanceID)
    try credentialPersistence.github.save(snapshot.githubCredentials, scope: scope)
    try credentialPersistence.openRouter.save(snapshot.openRouterCredentials, scope: scope)
    if ownership == .managed {
      try credentialPersistence.github.delete(scope: .legacy)
      try credentialPersistence.openRouter.delete(scope: .legacy)
    }
    try HarnessMonitorStore.persistKeyMaterial(
      runtime: snapshot.runtimeConfig,
      instanceID: instanceID,
      ownership: ownership,
      keychain: keyMaterialPersistence
    )
  }

  func completeRuntimeSecretHandoffIfNeeded(
    client: any HarnessMonitorClientProtocol,
    instanceID: String,
    ownership: DaemonOwnership
  ) async -> Bool {
    if let operation = secretHandoffOperation {
      let result = await operation.task.value
      clearSecretHandoffOperation(id: operation.id)
      if operation.instanceID == instanceID {
        return result
      }
    }
    let keychain = keyMaterialPersistence
    let task = Task {
      await HarnessMonitorStore.completeRuntimeSecretHandoffIfNeeded(
        client: client,
        instanceID: instanceID,
        ownership: ownership,
        keychain: keychain
      )
    }
    let operation = TaskBoardSecretHandoffOperation(instanceID: instanceID, task: task)
    secretHandoffOperation = operation
    let result = await task.value
    clearSecretHandoffOperation(id: operation.id)
    return result
  }

  private func clearSecretHandoffOperation(id: UUID) {
    if secretHandoffOperation?.id == id {
      secretHandoffOperation = nil
    }
  }

  private func loadScopedCredential<Snapshot: Equatable>(
    context: TaskBoardCredentialLoadContext,
    empty: Snapshot,
    load: (TaskBoardCredentialScope) throws -> Snapshot,
    save: (Snapshot, TaskBoardCredentialScope) throws -> Void,
    delete: (TaskBoardCredentialScope) throws -> Void
  ) throws -> Snapshot {
    let owned = try load(context.scope)
    guard context.migratesLegacy else {
      return owned
    }
    if owned != empty {
      try delete(.legacy)
      return owned
    }
    let legacy = try load(.legacy)
    guard legacy != empty else {
      return owned
    }
    try save(legacy, context.scope)
    guard try load(context.scope) == legacy else {
      throw TaskBoardKeyMaterialStoreError.invalidPayload
    }
    try delete(.legacy)
    return legacy
  }

  func waitForIdle() {}

  func migrateStoredSecrets(
    from oldInstanceID: String,
    to newInstanceID: String
  ) throws {
    let oldScope = TaskBoardCredentialScope.database(oldInstanceID)
    let newScope = TaskBoardCredentialScope.database(newInstanceID)

    let oldGithub = try credentialPersistence.github.load(scope: oldScope)
    let newGithub = try credentialPersistence.github.load(scope: newScope)
    let mergedGithub = mergeGithubCredential(old: oldGithub, new: newGithub)
    if mergedGithub != newGithub, !mergedGithub.isEmpty {
      try credentialPersistence.github.save(mergedGithub, scope: newScope)
    }

    let oldOpenRouter = try credentialPersistence.openRouter.load(scope: oldScope)
    let newOpenRouter = try credentialPersistence.openRouter.load(scope: newScope)
    let mergedOpenRouter = TaskBoardOpenRouterCredentialSnapshot(
      token: newOpenRouter.token ?? oldOpenRouter.token
    )
    if mergedOpenRouter != newOpenRouter, !mergedOpenRouter.isEmpty {
      try credentialPersistence.openRouter.save(mergedOpenRouter, scope: newScope)
    }

    try migrateKeyMaterial(
      from: .databaseGlobal(oldInstanceID),
      to: .databaseGlobal(newInstanceID)
    )

    let migratedRepos = Set(
      oldGithub.repositoryTokens.map { $0.repository.lowercased() }
        + newGithub.repositoryTokens.map { $0.repository.lowercased() }
    )
    for slug in migratedRepos {
      try migrateKeyMaterial(
        from: .databaseRepository(oldInstanceID, slug),
        to: .databaseRepository(newInstanceID, slug)
      )
    }
  }

  private func mergeGithubCredential(
    old: TaskBoardGitHubCredentialSnapshot,
    new: TaskBoardGitHubCredentialSnapshot
  ) -> TaskBoardGitHubCredentialSnapshot {
    var tokensByRepo = Dictionary(
      new.repositoryTokens.map { ($0.repository.lowercased(), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    for oldToken in old.repositoryTokens {
      let slug = oldToken.repository.lowercased()
      if tokensByRepo[slug] == nil {
        tokensByRepo[slug] = oldToken
      }
    }
    let mergedTokens = tokensByRepo.values.sorted { $0.repository < $1.repository }
    return TaskBoardGitHubCredentialSnapshot(
      globalToken: new.globalToken ?? old.globalToken,
      repositoryTokens: mergedTokens
    )
  }

  private func migrateKeyMaterial(
    from oldScope: TaskBoardKeyMaterialStore.Scope,
    to newScope: TaskBoardKeyMaterialStore.Scope
  ) throws {
    let stores: [any TaskBoardKeyMaterialPersisting] = [
      keyMaterialPersistence.ssh,
      keyMaterialPersistence.signingSsh,
      keyMaterialPersistence.gpg,
    ]
    for store in stores {
      let oldMaterial = try store.load(scope: oldScope)
      guard !oldMaterial.isEmpty else { continue }
      let newMaterial = try store.load(scope: newScope)
      let merged = TaskBoardKeyMaterialSnapshot(
        privateKey: newMaterial.privateKey ?? oldMaterial.privateKey,
        passphrase: newMaterial.passphrase ?? oldMaterial.passphrase,
        keyPath: newMaterial.keyPath ?? oldMaterial.keyPath,
        keyId: newMaterial.keyId ?? oldMaterial.keyId
      )
      if merged != newMaterial, !merged.isEmpty {
        try store.save(merged, scope: newScope)
      }
    }
  }
}
