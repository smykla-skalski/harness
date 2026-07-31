import Foundation

extension TaskBoardSettingsWorker {
  /// One key-material store paired with the secret kinds it produces at the
  /// global and per-repository scopes.
  private struct KeyMaterialTarget {
    let store: any TaskBoardKeyMaterialPersisting
    let globalKind: TaskBoardSecretKind
    let repositoryKind: (String) -> TaskBoardSecretKind
  }

  private var keyMaterialTargets: [KeyMaterialTarget] {
    [
      KeyMaterialTarget(
        store: keyMaterialPersistence.ssh,
        globalKind: .sshKey,
        repositoryKind: { .repositorySSHKey($0) }
      ),
      KeyMaterialTarget(
        store: keyMaterialPersistence.signingSsh,
        globalKind: .signingSSHKey,
        repositoryKind: { .repositorySigningSSHKey($0) }
      ),
      KeyMaterialTarget(
        store: keyMaterialPersistence.gpg,
        globalKind: .gpgKey,
        repositoryKind: { .repositoryGPGKey($0) }
      ),
    ]
  }

  /// Secrets present on the old daemon that can move to the new one. Conflicts
  /// (the new daemon already holds a differing value) come first, then safe
  /// carry-overs. Secrets already identical on both daemons are omitted.
  func secretMigrationItems(
    from oldInstanceID: String,
    to newInstanceID: String,
    knownRepositories: Set<String>
  ) throws -> [TaskBoardSecretMigrationItem] {
    let oldScope = TaskBoardCredentialScope.database(oldInstanceID)
    let newScope = TaskBoardCredentialScope.database(newInstanceID)
    var conflicts: [TaskBoardSecretMigrationItem] = []
    var carryOvers: [TaskBoardSecretMigrationItem] = []

    func consider(
      _ kind: TaskBoardSecretKind,
      _ disposition: TaskBoardSecretMigrationItem.Disposition?
    ) {
      switch disposition {
      case .conflict:
        conflicts.append(TaskBoardSecretMigrationItem(kind: kind, disposition: .conflict))
      case .carryOver:
        carryOvers.append(TaskBoardSecretMigrationItem(kind: kind, disposition: .carryOver))
      case nil:
        break
      }
    }

    let oldGithub = try credentialPersistence.github.load(scope: oldScope)
    let newGithub = try credentialPersistence.github.load(scope: newScope)
    consider(.githubGlobalToken, stringDisposition(oldGithub.globalToken, newGithub.globalToken))

    let oldOpenRouter = try credentialPersistence.openRouter.load(scope: oldScope)
    let newOpenRouter = try credentialPersistence.openRouter.load(scope: newScope)
    consider(.openRouterToken, stringDisposition(oldOpenRouter.token, newOpenRouter.token))

    for target in keyMaterialTargets {
      consider(
        target.globalKind,
        try keyMaterialDisposition(
          target.store,
          old: .databaseGlobal(oldInstanceID),
          new: .databaseGlobal(newInstanceID)
        )
      )
    }

    let oldRepoTokens = repositoryTokenMap(oldGithub)
    let newRepoTokens = repositoryTokenMap(newGithub)
    for slug in oldRepoTokens.keys.sorted() {
      consider(
        .repositoryGitHubToken(slug),
        stringDisposition(oldRepoTokens[slug], newRepoTokens[slug])
      )
    }

    let repoSlugs = repositorySlugs(
      oldGithub: oldGithub,
      newGithub: newGithub,
      known: knownRepositories
    )
    for slug in repoSlugs.sorted() {
      for target in keyMaterialTargets {
        consider(
          target.repositoryKind(slug),
          try keyMaterialDisposition(
            target.store,
            old: .databaseRepository(oldInstanceID, slug),
            new: .databaseRepository(newInstanceID, slug)
          )
        )
      }
    }
    return conflicts + carryOvers
  }

  /// Writes the previous daemon's value into the new scope for every secret the
  /// user approved in `selections`, and leaves the rest untouched.
  func migrateStoredSecrets(
    from oldInstanceID: String,
    to newInstanceID: String,
    knownRepositories: Set<String>,
    selections: TaskBoardSecretMigrationSelections
  ) throws {
    let oldScope = TaskBoardCredentialScope.database(oldInstanceID)
    let newScope = TaskBoardCredentialScope.database(newInstanceID)

    let oldGithub = try credentialPersistence.github.load(scope: oldScope)
    let newGithub = try credentialPersistence.github.load(scope: newScope)
    let mergedGithub = mergedGithubCredential(
      old: oldGithub,
      new: newGithub,
      selections: selections
    )
    if mergedGithub != newGithub, !mergedGithub.isEmpty {
      try credentialPersistence.github.save(mergedGithub, scope: newScope)
    }

    let oldOpenRouter = try credentialPersistence.openRouter.load(scope: oldScope)
    let newOpenRouter = try credentialPersistence.openRouter.load(scope: newScope)
    let openRouterToken =
      selections[.openRouterToken] == true ? oldOpenRouter.token : newOpenRouter.token
    let mergedOpenRouter = TaskBoardOpenRouterCredentialSnapshot(token: openRouterToken)
    if mergedOpenRouter != newOpenRouter, !mergedOpenRouter.isEmpty {
      try credentialPersistence.openRouter.save(mergedOpenRouter, scope: newScope)
    }

    for target in keyMaterialTargets {
      try carryKeyMaterial(
        target.store,
        from: .databaseGlobal(oldInstanceID),
        to: .databaseGlobal(newInstanceID),
        carry: selections[target.globalKind] == true
      )
    }

    let repoSlugs = repositorySlugs(
      oldGithub: oldGithub,
      newGithub: newGithub,
      known: knownRepositories
    )
    for slug in repoSlugs.sorted() {
      for target in keyMaterialTargets {
        try carryKeyMaterial(
          target.store,
          from: .databaseRepository(oldInstanceID, slug),
          to: .databaseRepository(newInstanceID, slug),
          carry: selections[target.repositoryKind(slug)] == true
        )
      }
    }
  }

  private func mergedGithubCredential(
    old: TaskBoardGitHubCredentialSnapshot,
    new: TaskBoardGitHubCredentialSnapshot,
    selections: TaskBoardSecretMigrationSelections
  ) -> TaskBoardGitHubCredentialSnapshot {
    var tokensByRepo = Dictionary(
      new.repositoryTokens.map { ($0.repository.lowercased(), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    for oldToken in old.repositoryTokens {
      let slug = oldToken.repository.lowercased()
      if selections[.repositoryGitHubToken(slug)] == true {
        tokensByRepo[slug] = oldToken
      }
    }
    let mergedTokens = tokensByRepo.values.sorted { $0.repository < $1.repository }
    let globalToken = selections[.githubGlobalToken] == true ? old.globalToken : new.globalToken
    return TaskBoardGitHubCredentialSnapshot(
      globalToken: globalToken,
      repositoryTokens: mergedTokens
    )
  }

  private func carryKeyMaterial(
    _ store: any TaskBoardKeyMaterialPersisting,
    from oldScope: TaskBoardKeyMaterialStore.Scope,
    to newScope: TaskBoardKeyMaterialStore.Scope,
    carry: Bool
  ) throws {
    guard carry else { return }
    let old = try store.load(scope: oldScope)
    guard !old.isEmpty else { return }
    if try store.load(scope: newScope) != old {
      try store.save(old, scope: newScope)
    }
  }

  private func keyMaterialDisposition(
    _ store: any TaskBoardKeyMaterialPersisting,
    old oldScope: TaskBoardKeyMaterialStore.Scope,
    new newScope: TaskBoardKeyMaterialStore.Scope
  ) throws -> TaskBoardSecretMigrationItem.Disposition? {
    let old = try store.load(scope: oldScope)
    guard !old.isEmpty else { return nil }
    let new = try store.load(scope: newScope)
    if new.isEmpty { return .carryOver }
    return old == new ? nil : .conflict
  }

  private func stringDisposition(
    _ old: String?,
    _ new: String?
  ) -> TaskBoardSecretMigrationItem.Disposition? {
    guard let old, !old.isEmpty else { return nil }
    guard let new, !new.isEmpty else { return .carryOver }
    return old == new ? nil : .conflict
  }

  private func repositoryTokenMap(
    _ snapshot: TaskBoardGitHubCredentialSnapshot
  ) -> [String: String] {
    Dictionary(
      snapshot.repositoryTokens.map { ($0.repository.lowercased(), $0.token) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private func repositorySlugs(
    oldGithub: TaskBoardGitHubCredentialSnapshot,
    newGithub: TaskBoardGitHubCredentialSnapshot,
    known: Set<String>
  ) -> Set<String> {
    var slugs = Set(known.map { $0.lowercased() })
    slugs.formUnion(oldGithub.repositoryTokens.map { $0.repository.lowercased() })
    slugs.formUnion(newGithub.repositoryTokens.map { $0.repository.lowercased() })
    return slugs
  }
}
