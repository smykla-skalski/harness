import SwiftData

/// V18 is purely additive: one new entity (CachedDependencyRepositoryLabels)
/// keyed by `repository` so the label picker can populate without depending
/// on the per-preferences-hash snapshot that V17 introduced. Lightweight
/// migration adds the empty table; the dashboard upserts rows on the next
/// successful dependency-updates query.
public enum HarnessMonitorSchemaV18: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(18, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV14.CachedProject.self,
      HarnessMonitorSchemaV14.CachedSession.self,
      HarnessMonitorSchemaV14.CachedAgent.self,
      HarnessMonitorSchemaV14.CachedWorkItem.self,
      HarnessMonitorSchemaV14.CachedSignalRecord.self,
      HarnessMonitorSchemaV14.CachedTimelineEntry.self,
      HarnessMonitorSchemaV14.CachedObserver.self,
      HarnessMonitorSchemaV14.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      NotificationHistoryRecord.self,
      CachedTaskBoardSnapshot.self,
      CachedDependencyUpdatesSnapshot.self,
      CachedDependencyRepositoryLabels.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
    ]
  }
}

/// V19 is purely additive: one new entity (CachedDependencyLabelUsage) keyed
/// by `(repository, label)` so the label picker can surface a per-repo
/// "Frequently Used" section. Lightweight migration adds the empty table; the
/// dashboard upserts rows after a successful addLabel mutation.
public enum HarnessMonitorSchemaV19: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(19, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV14.CachedProject.self,
      HarnessMonitorSchemaV14.CachedSession.self,
      HarnessMonitorSchemaV14.CachedAgent.self,
      HarnessMonitorSchemaV14.CachedWorkItem.self,
      HarnessMonitorSchemaV14.CachedSignalRecord.self,
      HarnessMonitorSchemaV14.CachedTimelineEntry.self,
      HarnessMonitorSchemaV14.CachedObserver.self,
      HarnessMonitorSchemaV14.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      NotificationHistoryRecord.self,
      CachedTaskBoardSnapshot.self,
      CachedDependencyUpdatesSnapshot.self,
      CachedDependencyRepositoryLabels.self,
      CachedDependencyLabelUsage.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
    ]
  }
}

/// V20 is purely additive: one new entity (CachedDependencyUpdatesRepoSyncState)
/// keyed by `(preferencesHash, repository)` so the per-repository dependency
/// scheduler can resume oldest-first across relaunches. Lightweight migration
/// adds the empty table; the dashboard upserts rows after each successful
/// per-repo dependency-updates query.
public enum HarnessMonitorSchemaV20: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(20, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV14.CachedProject.self,
      HarnessMonitorSchemaV14.CachedSession.self,
      HarnessMonitorSchemaV14.CachedAgent.self,
      HarnessMonitorSchemaV14.CachedWorkItem.self,
      HarnessMonitorSchemaV14.CachedSignalRecord.self,
      HarnessMonitorSchemaV14.CachedTimelineEntry.self,
      HarnessMonitorSchemaV14.CachedObserver.self,
      HarnessMonitorSchemaV14.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      NotificationHistoryRecord.self,
      CachedTaskBoardSnapshot.self,
      CachedDependencyUpdatesSnapshot.self,
      CachedDependencyRepositoryLabels.self,
      CachedDependencyLabelUsage.self,
      CachedDependencyUpdatesRepoSyncState.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
    ]
  }
}

public enum HarnessMonitorMigrationPlan: SchemaMigrationPlan {
  public static var schemas: [any VersionedSchema.Type] {
    [
      HarnessMonitorSchemaV1.self,
      HarnessMonitorSchemaV2.self,
      HarnessMonitorSchemaV3.self,
      HarnessMonitorSchemaV4.self,
      HarnessMonitorSchemaV5.self,
      HarnessMonitorSchemaV6.self,
      HarnessMonitorSchemaV7.self,
      HarnessMonitorSchemaV8.self,
      HarnessMonitorSchemaV9.self,
      HarnessMonitorSchemaV10.self,
      HarnessMonitorSchemaV11.self,
      HarnessMonitorSchemaV12.self,
      HarnessMonitorSchemaV13.self,
      HarnessMonitorSchemaV14.self,
      HarnessMonitorSchemaV15.self,
      HarnessMonitorSchemaV16.self,
      HarnessMonitorSchemaV17.self,
      HarnessMonitorSchemaV18.self,
      HarnessMonitorSchemaV19.self,
      HarnessMonitorSchemaV20.self,
      HarnessMonitorSchemaV21.self,
      HarnessMonitorSchemaV22.self,
      HarnessMonitorSchemaV23.self,
    ]
  }

  public static var stages: [MigrationStage] {
    [
      migrateV1toV2,
      migrateV2toV3,
      migrateV3toV4,
      migrateV4toV5,
      migrateV5toV6,
      migrateV6toV7,
      migrateV7toV8,
      migrateV8toV9,
      migrateV9toV10,
      migrateV10toV11,
      migrateV11toV12,
      migrateV12toV13,
      migrateV13toV14,
      migrateV14toV15,
      migrateV15toV16,
      migrateV16toV17,
      migrateV17toV18,
      migrateV18toV19,
      migrateV19toV20,
      migrateV20toV21,
      migrateV21toV22,
      migrateV22toV23,
    ]
  }

  static let migrateV1toV2 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV1.self,
    toVersion: HarnessMonitorSchemaV2.self
  )

  static let migrateV2toV3 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV2.self,
    toVersion: HarnessMonitorSchemaV3.self
  )

  static let migrateV3toV4 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV3.self,
    toVersion: HarnessMonitorSchemaV4.self
  )

  static let migrateV4toV5 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV4.self,
    toVersion: HarnessMonitorSchemaV5.self
  )

  // V5 fields isWorktree/worktreeName/checkoutId/checkoutRoot are removed; V6 adds
  // worktreePath/sharedPath/originPath/branchRef with empty-string defaults. SwiftData lightweight
  // migration drops removed columns and fills new ones with their declared defaults. The daemon
  // refreshes all workspace layout fields on the next sync cycle, so "" defaults are safe and
  // users see no visible data loss.
  //
  // A .custom stage that translates V5.isWorktree into a best-effort V6.branchRef seed was
  // evaluated and rejected: calling `context.fetch(FetchDescriptor<HarnessMonitorSchemaV5.CachedSession>())`
  // inside didMigrate trips a SwiftData typealias cast error at runtime. If a future migration
  // needs real translation, use the raw SQLite path or a pre-migration pass that reads the
  // SchemaV5 store directly; do NOT revive the FetchDescriptor-in-didMigrate approach.
  static let migrateV5toV6 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV5.self,
    toVersion: HarnessMonitorSchemaV6.self
  )

  // V7 is purely additive: three new entities (Decision, SupervisorEvent, PolicyConfigRow)
  // with no relationship to the V6 set. Lightweight migration is the correct stage because
  // nothing changes on existing rows and the new tables start empty.
  static let migrateV6toV7 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV6.self,
    toVersion: HarnessMonitorSchemaV7.self
  )

  // V8 is purely additive: one new entity (CachedTaskReviewMetadata) with
  // its own (sessionId, taskId) key and no relationship into the V6/V7
  // model graph. Lightweight migration adds the empty table; the Swift
  // conversion layer populates rows on the next sync and treats a
  // missing row as an empty review metadata block.
  static let migrateV7toV8 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV7.self,
    toVersion: HarnessMonitorSchemaV8.self
  )

  static let migrateV8toV9 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV8.self,
    toVersion: HarnessMonitorSchemaV9.self
  )

  // V10 adds three optional/default fields to CachedSessionWindowState
  // (tabGroupOrdinal, tabPosition, wasForegroundTab). Lightweight migration
  // fills the new columns with nil/false on existing rows; the next quit
  // populates them per current tab-group state.
  static let migrateV9toV10 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV9.self,
    toVersion: HarnessMonitorSchemaV10.self
  )

  // V11 is purely additive: one new transcript side-table with a `(sessionId, entryId)`
  // key and no relationship back into the cached session graph. Lightweight migration adds
  // the empty table; the cache sync path repopulates rows on the next refresh.
  static let migrateV10toV11 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV10.self,
    toVersion: HarnessMonitorSchemaV11.self
  )

  // V12 adds one transcript provenance column (`sourceRaw`) to the V11 side-table.
  // The field stays optional because SwiftData lightweight migration cannot fill
  // non-optional defaults on existing rows. The read path treats nil as `.cache`,
  // and the next live refresh rewrites rows with direct/derived provenance.
  static let migrateV11toV12 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV11.self,
    toVersion: HarnessMonitorSchemaV12.self
  )

  // Historical V13 is purely additive: one managed-agent identity side-table keyed
  // by `(sessionId, agentId)` with no relationship into the V6 cached session
  // graph. Lightweight migration adds the table; V12 rows remain readable even
  // before any managed-agent metadata has been written.
  static let migrateV12toV13 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV12.self,
    toVersion: HarnessMonitorSchemaV13.self
  )

  // V14 moves managed-agent identity from the historical V13 side-table onto
  // CachedAgent directly. The only live-entity storage change is two optional
  // columns on CachedAgent (`managedAgentID`, `managedAgentKindRaw`), so staged
  // migration from the known V13 side-table store to the V14 graph remains
  // lightweight. The old side-table becomes orphaned SQLite data and is ignored.
  static let migrateV13toV14 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV13.self,
    toVersion: HarnessMonitorSchemaV14.self
  )

  static let migrateV14toV15 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV14.self,
    toVersion: HarnessMonitorSchemaV15.self
  )

  static let migrateV15toV16 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV15.self,
    toVersion: HarnessMonitorSchemaV16.self
  )

  // V17 is purely additive: one new entity (CachedDependencyUpdatesSnapshot)
  // keyed by `preferencesHash` with no relationship into the V14 cached session
  // graph. Lightweight migration adds the empty table; the dashboard cache
  // writer populates rows on the next dependency-updates query.
  static let migrateV16toV17 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV16.self,
    toVersion: HarnessMonitorSchemaV17.self
  )

  // V18 is purely additive: one new entity (CachedDependencyRepositoryLabels)
  // keyed by `repository` so the dependency label picker can populate from a
  // per-repo cache that survives changes to the per-preferences-hash bucket.
  // Lightweight migration adds the empty table; the dashboard upserts rows on
  // the next successful dependency-updates query.
  static let migrateV17toV18 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV17.self,
    toVersion: HarnessMonitorSchemaV18.self
  )

  // V19 is purely additive: one new entity (CachedDependencyLabelUsage) keyed
  // by `(repository, label)` so the dependency label picker can surface a
  // per-repo "Frequently Used" section. Lightweight migration adds the empty
  // table; the dashboard upserts rows after a successful addLabel mutation.
  static let migrateV18toV19 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV18.self,
    toVersion: HarnessMonitorSchemaV19.self
  )

  // V20 is purely additive: one new entity (CachedDependencyUpdatesRepoSyncState)
  // keyed by `(preferencesHash, repository)` so the per-repository dependency
  // scheduler can resume oldest-first across relaunches. Lightweight migration
  // adds the empty table; the dashboard upserts rows after each successful
  // per-repo dependency-updates query.
  static let migrateV19toV20 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV19.self,
    toVersion: HarnessMonitorSchemaV20.self
  )

  // V21 is purely additive: three new entities for the Dependencies > Files
  // per-PR file cache. `CachedDependencyUpdateFilesSummary` keys by
  // `pullRequestID`; the per-file metadata and per-file viewed state both
  // use a compound `pullRequestID + headRefOid + path` key. Lightweight
  // migration adds the empty tables; the dashboard repopulates them on the
  // next `list_dependency_update_files` daemon round-trip.
  static let migrateV20toV21 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV20.self,
    toVersion: HarnessMonitorSchemaV21.self
  )

  // V22 renames the V17–V21 cached `CachedDependency*` entities to
  // `CachedReview*` so the dashboard's "Reviews" feature stops carrying the
  // historical "Dependencies" label. The class-name change makes SwiftData
  // treat the old and new entities as distinct, so the V21→V22 stage is a
  // custom migration that copies each row from the old class into the new
  // class and deletes the source row.
  static let migrateV21toV22 = HarnessMonitorMigrationV21ToV22.stage

  // V23 is purely additive: one avatar cache table keyed by exact GitHub
  // `avatarUrl`, with no relationships into the existing V22 graph.
  static let migrateV22toV23 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV22.self,
    toVersion: HarnessMonitorSchemaV23.self
  )
}

public typealias HarnessMonitorCurrentSchema = HarnessMonitorSchemaV23
