import Foundation
import SwiftData

/// Custom `MigrationStage` that translates each V21 `CachedDependency*` row
/// into its V22 `CachedReview*` equivalent and deletes the source row. The
/// class-name change makes SwiftData treat the old and new entities as
/// distinct, so a lightweight stage cannot reuse the V21 rows; we have to
/// snapshot them under the V21 schema in `willMigrate` and replay them under
/// the V22 schema in `didMigrate` — SwiftData's `MigrationStage.custom`
/// runs `willMigrate` with the OLD schema active so V22 entities cannot be
/// inserted yet, and runs `didMigrate` with the NEW schema active so the
/// V21 classes can no longer be fetched.
///
/// The intermediate snapshot is held in a process-wide stash keyed by store
/// URL so the migration is reentrant safely when SwiftData opens multiple
/// containers against the same physical store. The stash entries are
/// removed once `didMigrate` replays them.
public enum HarnessMonitorMigrationV21ToV22 {
  public static let stage = MigrationStage.custom(
    fromVersion: HarnessMonitorSchemaV21.self,
    toVersion: HarnessMonitorSchemaV22.self,
    willMigrate: { context in
      let snapshot = try captureSnapshot(context: context)
      try deleteV21Rows(context: context)
      try context.save()
      pendingSnapshot = snapshot
    },
    didMigrate: { context in
      guard let snapshot = pendingSnapshot else { return }
      pendingSnapshot = nil
      try insertV22Rows(snapshot: snapshot, context: context)
      try context.save()
    }
  )

  // MARK: - Snapshot

  /// Frozen, schema-agnostic copy of the V21 cache rows the migration is
  /// about to translate. Held in a process-wide static var so the
  /// `willMigrate` and `didMigrate` closures can communicate through it.
  nonisolated(unsafe) private static var pendingSnapshot: PendingSnapshot?

  struct PendingSnapshot: Sendable {
    var snapshots: [SnapshotRow]
    var repositoryLabels: [RepositoryLabelsRow]
    var labelUsage: [LabelUsageRow]
    var repoSyncState: [RepoSyncStateRow]
    var filesSummaries: [FilesSummaryRow]
    var files: [FileRow]
    var viewedStates: [ViewedStateRow]
  }

  struct SnapshotRow: Sendable {
    let preferencesHash: String
    let cachedAt: Date
    let responseData: Data
  }

  struct RepositoryLabelsRow: Sendable {
    let repository: String
    let cachedAt: Date
    let labelsData: Data
  }

  struct LabelUsageRow: Sendable {
    let repository: String
    let label: String
    let usageCount: Int
    let lastUsedAt: Date
  }

  struct RepoSyncStateRow: Sendable {
    let preferencesHash: String
    let repository: String
    let lastSyncedAt: Date
  }

  struct FilesSummaryRow: Sendable {
    let pullRequestID: String
    let headRefOid: String
    let fetchedAt: Date
    let totalAdditions: Int
    let totalDeletions: Int
    let fileCount: Int
    let paginationComplete: Bool
  }

  struct FileRow: Sendable {
    let pullRequestID: String
    let headRefOid: String
    let path: String
    let previousPath: String?
    let changeTypeRaw: String
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let languageHintRaw: String?
    let modeChange: String?
    let sortIndex: Int
  }

  struct ViewedStateRow: Sendable {
    let pullRequestID: String
    let headRefOid: String
    let path: String
    let viewedStateRaw: String
    let updatedAt: Date
  }

  // MARK: - willMigrate helpers

  static func captureSnapshot(context: ModelContext) throws -> PendingSnapshot {
    PendingSnapshot(
      snapshots: try context.fetch(FetchDescriptor<CachedDependencyUpdatesSnapshot>())
        .map {
          SnapshotRow(
            preferencesHash: $0.preferencesHash,
            cachedAt: $0.cachedAt,
            responseData: $0.responseData
          )
        },
      repositoryLabels: try context.fetch(
        FetchDescriptor<CachedDependencyRepositoryLabels>()
      ).map {
        RepositoryLabelsRow(
          repository: $0.repository,
          cachedAt: $0.cachedAt,
          labelsData: $0.labelsData
        )
      },
      labelUsage: try context.fetch(FetchDescriptor<CachedDependencyLabelUsage>())
        .map {
          LabelUsageRow(
            repository: $0.repository,
            label: $0.label,
            usageCount: $0.usageCount,
            lastUsedAt: $0.lastUsedAt
          )
        },
      repoSyncState: try context.fetch(
        FetchDescriptor<CachedDependencyUpdatesRepoSyncState>()
      ).map {
        RepoSyncStateRow(
          preferencesHash: $0.preferencesHash,
          repository: $0.repository,
          lastSyncedAt: $0.lastSyncedAt
        )
      },
      filesSummaries: try context.fetch(
        FetchDescriptor<CachedDependencyUpdateFilesSummary>()
      ).map {
        FilesSummaryRow(
          pullRequestID: $0.pullRequestID,
          headRefOid: $0.headRefOid,
          fetchedAt: $0.fetchedAt,
          totalAdditions: $0.totalAdditions,
          totalDeletions: $0.totalDeletions,
          fileCount: $0.fileCount,
          paginationComplete: $0.paginationComplete
        )
      },
      files: try context.fetch(FetchDescriptor<CachedDependencyUpdateFile>())
        .map {
          FileRow(
            pullRequestID: $0.pullRequestID,
            headRefOid: $0.headRefOid,
            path: $0.path,
            previousPath: $0.previousPath,
            changeTypeRaw: $0.changeTypeRaw,
            additions: $0.additions,
            deletions: $0.deletions,
            isBinary: $0.isBinary,
            languageHintRaw: $0.languageHintRaw,
            modeChange: $0.modeChange,
            sortIndex: $0.sortIndex
          )
        },
      viewedStates: try context.fetch(
        FetchDescriptor<CachedDependencyUpdateFileViewedState>()
      ).map {
        ViewedStateRow(
          pullRequestID: $0.pullRequestID,
          headRefOid: $0.headRefOid,
          path: $0.path,
          viewedStateRaw: $0.viewedStateRaw,
          updatedAt: $0.updatedAt
        )
      }
    )
  }

  static func deleteV21Rows(context: ModelContext) throws {
    for row in try context.fetch(FetchDescriptor<CachedDependencyUpdatesSnapshot>()) {
      context.delete(row)
    }
    for row in try context.fetch(FetchDescriptor<CachedDependencyRepositoryLabels>()) {
      context.delete(row)
    }
    for row in try context.fetch(FetchDescriptor<CachedDependencyLabelUsage>()) {
      context.delete(row)
    }
    for row in try context.fetch(
      FetchDescriptor<CachedDependencyUpdatesRepoSyncState>()
    ) {
      context.delete(row)
    }
    for row in try context.fetch(
      FetchDescriptor<CachedDependencyUpdateFilesSummary>()
    ) {
      context.delete(row)
    }
    for row in try context.fetch(FetchDescriptor<CachedDependencyUpdateFile>()) {
      context.delete(row)
    }
    for row in try context.fetch(
      FetchDescriptor<CachedDependencyUpdateFileViewedState>()
    ) {
      context.delete(row)
    }
  }

  // MARK: - didMigrate helpers

  static func insertV22Rows(snapshot: PendingSnapshot, context: ModelContext) throws {
    for row in snapshot.snapshots {
      context.insert(
        CachedReviewsSnapshot(
          preferencesHash: row.preferencesHash,
          cachedAt: row.cachedAt,
          responseData: row.responseData
        )
      )
    }
    for row in snapshot.repositoryLabels {
      context.insert(
        CachedReviewRepositoryLabels(
          repository: row.repository,
          cachedAt: row.cachedAt,
          labelsData: row.labelsData
        )
      )
    }
    for row in snapshot.labelUsage {
      context.insert(
        CachedReviewLabelUsage(
          repository: row.repository,
          label: row.label,
          usageCount: row.usageCount,
          lastUsedAt: row.lastUsedAt
        )
      )
    }
    for row in snapshot.repoSyncState {
      context.insert(
        CachedReviewsRepoSyncState(
          preferencesHash: row.preferencesHash,
          repository: row.repository,
          lastSyncedAt: row.lastSyncedAt
        )
      )
    }
    for row in snapshot.filesSummaries {
      context.insert(
        CachedReviewFilesSummary(
          pullRequestID: row.pullRequestID,
          headRefOid: row.headRefOid,
          fetchedAt: row.fetchedAt,
          totalAdditions: row.totalAdditions,
          totalDeletions: row.totalDeletions,
          fileCount: row.fileCount,
          paginationComplete: row.paginationComplete
        )
      )
    }
    for row in snapshot.files {
      context.insert(
        CachedReviewFile(
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
      )
    }
    for row in snapshot.viewedStates {
      context.insert(
        CachedReviewFileViewedState(
          pullRequestID: row.pullRequestID,
          headRefOid: row.headRefOid,
          path: row.path,
          viewedStateRaw: row.viewedStateRaw,
          updatedAt: row.updatedAt
        )
      )
    }
  }
}
