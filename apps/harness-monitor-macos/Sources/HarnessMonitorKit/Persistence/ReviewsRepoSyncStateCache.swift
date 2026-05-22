import Foundation
import SwiftData

public struct ReviewsRepoSyncStateCache {
  private let context: ModelContext

  public init(context: ModelContext) {
    self.context = context
  }

  /// Return the persisted `lastSyncedAt` per repository for `preferencesHash`.
  /// Used at scheduler start so a relaunch resumes oldest-first instead of
  /// re-fetching every repository as if cold.
  public func loadStates(preferencesHash: String) -> [String: Date] {
    let descriptor = FetchDescriptor<CachedReviewsRepoSyncState>(
      predicate: #Predicate { $0.preferencesHash == preferencesHash }
    )
    guard let rows = try? context.fetch(descriptor) else { return [:] }
    var result: [String: Date] = [:]
    for row in rows {
      result[row.repository] = row.lastSyncedAt
    }
    return result
  }

  /// Upsert the (preferencesHash, repository) row with `syncedAt`. Called
  /// from the scheduler's per-repo merge callback so the next relaunch can
  /// hydrate the same staleness ordering.
  public func recordSyncedAt(
    preferencesHash: String,
    repository: String,
    syncedAt: Date = .now
  ) {
    guard !preferencesHash.isEmpty, !repository.isEmpty else { return }
    do {
      let key = CachedReviewsRepoSyncState.makeCompoundKey(
        preferencesHash: preferencesHash,
        repository: repository
      )
      let descriptor = FetchDescriptor<CachedReviewsRepoSyncState>(
        predicate: #Predicate { $0.compoundKey == key }
      )
      if let existing = try context.fetch(descriptor).first {
        existing.lastSyncedAt = syncedAt
      } else {
        let row = CachedReviewsRepoSyncState(
          preferencesHash: preferencesHash,
          repository: repository,
          lastSyncedAt: syncedAt
        )
        context.insert(row)
      }
      try context.save()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to record dependency repo sync state; \
        preferences_hash=\(preferencesHash, privacy: .public) \
        repository=\(repository, privacy: .public) \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
    }
  }

  /// Remove every row for `preferencesHash`. Called when preferences change
  /// in a way that obsoletes the per-repo bucket.
  public func deleteAll(preferencesHash: String) {
    let descriptor = FetchDescriptor<CachedReviewsRepoSyncState>(
      predicate: #Predicate { $0.preferencesHash == preferencesHash }
    )
    guard let rows = try? context.fetch(descriptor) else { return }
    for row in rows {
      context.delete(row)
    }
    try? context.save()
  }

  /// Remove every row regardless of bucket. Used by the diagnostic
  /// "Clear Session Cache" action.
  public func deleteAll() {
    let descriptor = FetchDescriptor<CachedReviewsRepoSyncState>()
    guard let rows = try? context.fetch(descriptor) else { return }
    for row in rows {
      context.delete(row)
    }
    try? context.save()
  }
}
