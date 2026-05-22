import Foundation
import SwiftData

/// Custom `MigrationStage` that translates each V21 `CachedDependency*` row
/// into its V22 `CachedReview*` equivalent and deletes the source row. The
/// class-name change makes SwiftData treat the old and new entities as
/// distinct, so a lightweight stage cannot reuse the V21 rows; we have to
/// copy them across the entity boundary explicitly.
///
/// The migration is intentionally row-by-row with explicit field copies so
/// that any field rename in a future schema bump stays a localized edit
/// rather than requiring a re-derivation of an opaque mapping. After the
/// stage runs, the `CachedDependency*` tables are empty and the `CachedReview*`
/// tables carry the previous contents; the helper definitions in
/// `CachedReviewLegacyV21Models.swift` remain in the binary for the same
/// reason `HarnessMonitorSchemaV21` does — so a store that has not yet been
/// opened under V22 can still be read by the migration plan.
public enum HarnessMonitorMigrationV21ToV22 {
  public static let stage = MigrationStage.custom(
    fromVersion: HarnessMonitorSchemaV21.self,
    toVersion: HarnessMonitorSchemaV22.self,
    willMigrate: { context in
      try migrateSnapshots(context: context)
      try migrateRepositoryLabels(context: context)
      try migrateLabelUsage(context: context)
      try migrateRepoSyncState(context: context)
      try migrateFilesSummaries(context: context)
      try migrateFiles(context: context)
      try migrateViewedStates(context: context)
      try context.save()
    },
    didMigrate: nil
  )

  static func migrateSnapshots(context: ModelContext) throws {
    let descriptor = FetchDescriptor<CachedDependencyUpdatesSnapshot>()
    let rows = try context.fetch(descriptor)
    for row in rows {
      let copy = CachedReviewsSnapshot(
        preferencesHash: row.preferencesHash,
        cachedAt: row.cachedAt,
        responseData: row.responseData
      )
      context.insert(copy)
      context.delete(row)
    }
  }

  static func migrateRepositoryLabels(context: ModelContext) throws {
    let descriptor = FetchDescriptor<CachedDependencyRepositoryLabels>()
    let rows = try context.fetch(descriptor)
    for row in rows {
      let copy = CachedReviewRepositoryLabels(
        repository: row.repository,
        cachedAt: row.cachedAt,
        labelsData: row.labelsData
      )
      context.insert(copy)
      context.delete(row)
    }
  }

  static func migrateLabelUsage(context: ModelContext) throws {
    let descriptor = FetchDescriptor<CachedDependencyLabelUsage>()
    let rows = try context.fetch(descriptor)
    for row in rows {
      let copy = CachedReviewLabelUsage(
        repository: row.repository,
        label: row.label,
        usageCount: row.usageCount,
        lastUsedAt: row.lastUsedAt
      )
      context.insert(copy)
      context.delete(row)
    }
  }

  static func migrateRepoSyncState(context: ModelContext) throws {
    let descriptor = FetchDescriptor<CachedDependencyUpdatesRepoSyncState>()
    let rows = try context.fetch(descriptor)
    for row in rows {
      let copy = CachedReviewsRepoSyncState(
        preferencesHash: row.preferencesHash,
        repository: row.repository,
        lastSyncedAt: row.lastSyncedAt
      )
      context.insert(copy)
      context.delete(row)
    }
  }

  static func migrateFilesSummaries(context: ModelContext) throws {
    let descriptor = FetchDescriptor<CachedDependencyUpdateFilesSummary>()
    let rows = try context.fetch(descriptor)
    for row in rows {
      let copy = CachedReviewFilesSummary(
        pullRequestID: row.pullRequestID,
        headRefOid: row.headRefOid,
        fetchedAt: row.fetchedAt,
        totalAdditions: row.totalAdditions,
        totalDeletions: row.totalDeletions,
        fileCount: row.fileCount,
        paginationComplete: row.paginationComplete
      )
      context.insert(copy)
      context.delete(row)
    }
  }

  static func migrateFiles(context: ModelContext) throws {
    let descriptor = FetchDescriptor<CachedDependencyUpdateFile>()
    let rows = try context.fetch(descriptor)
    for row in rows {
      let copy = CachedReviewFile(
        pullRequestID: row.pullRequestID,
        headRefOid: row.headRefOid,
        path: row.path,
        previousPath: row.previousPath,
        changeTypeRaw: row.changeTypeRaw,
        additions: row.additions,
        deletions: row.deletions,
        isBinary: row.isBinary,
        languageHintRaw: row.languageHintRaw,
        modeChange: row.modeChange,
        sortIndex: row.sortIndex
      )
      context.insert(copy)
      context.delete(row)
    }
  }

  static func migrateViewedStates(context: ModelContext) throws {
    let descriptor = FetchDescriptor<CachedDependencyUpdateFileViewedState>()
    let rows = try context.fetch(descriptor)
    for row in rows {
      let copy = CachedReviewFileViewedState(
        pullRequestID: row.pullRequestID,
        headRefOid: row.headRefOid,
        path: row.path,
        viewedStateRaw: row.viewedStateRaw,
        updatedAt: row.updatedAt
      )
      context.insert(copy)
      context.delete(row)
    }
  }
}
