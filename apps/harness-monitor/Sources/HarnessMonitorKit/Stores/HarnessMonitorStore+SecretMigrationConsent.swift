import Foundation

struct TaskBoardSecretMigrationConsentState: Sendable {
  let items: [TaskBoardSecretMigrationItem]
  var continuation: CheckedContinuation<TaskBoardSecretMigrationSelections?, Never>?
}

extension HarnessMonitorStore {
  /// Records a freshly connected daemon identity. When it differs from the last
  /// one connected this session, that prior id becomes the migration source so
  /// stored secrets follow the user to the new daemon.
  func noteConnectedDatabaseInstance(_ instanceID: String) {
    let lastConnected = taskBoardRuntimeState.connection.lastConnectedDatabaseInstanceID
    if let lastConnected, lastConnected != instanceID {
      taskBoardRuntimeState.connection.previousDatabaseInstanceID = lastConnected
    }
    taskBoardRuntimeState.connection.lastConnectedDatabaseInstanceID = instanceID
  }

  /// Remembers which repositories carry per-repo overrides for `instanceID`,
  /// gleaned from a runtime config fetch, so their key material can migrate
  /// even when no matching GitHub token exists.
  func recordTaskBoardRepositoryOverrides(
    instanceID: String,
    runtime: TaskBoardGitRuntimeConfig
  ) {
    let slugs = Set(runtime.repositoryOverrides.map { $0.repository.lowercased() })
    guard !slugs.isEmpty else { return }
    taskBoardRuntimeState.connection.databaseRepositoryOverrideSlugs[instanceID, default: []]
      .formUnion(slugs)
  }

  func knownTaskBoardRepositorySlugs(for instanceIDs: String?...) -> Set<String> {
    var slugs: Set<String> = []
    for instanceID in instanceIDs.compactMap({ $0 }) {
      slugs.formUnion(
        taskBoardRuntimeState.connection.databaseRepositoryOverrideSlugs[instanceID] ?? []
      )
    }
    return slugs
  }

  /// Reviews the secrets carried from the previous daemon to the newly
  /// connected one. Whenever there is anything to carry, a review sheet lets the
  /// user resolve conflicts and opt out of any carry-over; dismissing it carries
  /// nothing. Nothing is written or pushed until the user applies. The migration
  /// source is cleared once the review completes, so it does not nag on every
  /// reconnect, but a scan or write failure retries on the next switch.
  func migrateStoredTaskBoardSecrets(from previousID: String, to currentID: String) async {
    let knownRepositories = knownTaskBoardRepositorySlugs(for: previousID, currentID)
    let items: [TaskBoardSecretMigrationItem]
    do {
      items = try await taskBoardSettingsWorker.secretMigrationItems(
        from: previousID,
        to: currentID,
        knownRepositories: knownRepositories
      )
    } catch {
      HarnessMonitorLogger.store.error(
        "task-board secret scan failed: \(error.localizedDescription, privacy: .public)"
      )
      return
    }

    guard !items.isEmpty else {
      taskBoardRuntimeState.connection.previousDatabaseInstanceID = nil
      return
    }

    // Dismissing the sheet carries nothing and still clears the source, so a
    // deliberate cancel is honored without a Keychain write and is not
    // re-prompted on the next reconnect.
    guard let selections = await presentSecretMigrationConsent(items) else {
      taskBoardRuntimeState.connection.previousDatabaseInstanceID = nil
      return
    }

    do {
      try await taskBoardSettingsWorker.migrateStoredSecrets(
        from: previousID,
        to: currentID,
        knownRepositories: knownRepositories,
        selections: selections
      )
      taskBoardRuntimeState.connection.previousDatabaseInstanceID = nil
    } catch {
      HarnessMonitorLogger.store.error(
        "task-board secret migration failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// Presents the review sheet and parks the connection sync until the user
  /// applies or dismisses it. Returns the per-secret choices, or `nil` when the
  /// prompt is dismissed without a choice (treated as carry nothing).
  func presentSecretMigrationConsent(
    _ items: [TaskBoardSecretMigrationItem]
  ) async -> TaskBoardSecretMigrationSelections? {
    await withCheckedContinuation { continuation in
      taskBoardRuntimeState.connection.secretMigrationConsent =
        TaskBoardSecretMigrationConsentState(
          items: items,
          continuation: continuation
        )
      presentedSheet = .resolveSecretMigration(items: items)
    }
  }

  /// Applies the user's choices and resumes the parked connection sync.
  public func resolveSecretMigrationConsent(_ selections: TaskBoardSecretMigrationSelections?) {
    guard let consent = taskBoardRuntimeState.connection.secretMigrationConsent else { return }
    taskBoardRuntimeState.connection.secretMigrationConsent = nil
    if case .resolveSecretMigration = presentedSheet {
      presentedSheet = nil
    }
    consent.continuation?.resume(returning: selections)
  }

  /// Fallback for a sheet dismissed by other means (Escape, window close):
  /// resumes the parked sync with no explicit choice.
  func cancelSecretMigrationConsentIfPending() {
    guard let consent = taskBoardRuntimeState.connection.secretMigrationConsent else { return }
    taskBoardRuntimeState.connection.secretMigrationConsent = nil
    consent.continuation?.resume(returning: nil)
  }
}
