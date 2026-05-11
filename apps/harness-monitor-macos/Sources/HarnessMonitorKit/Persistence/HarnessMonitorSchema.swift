import Foundation
import SwiftData

extension VersionedSchema {
  public static var versionString: String {
    let version = versionIdentifier
    return "\(version.major).\(version.minor).\(version.patch)"
  }
}

public enum HarnessMonitorSchemaV1: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      Self.CachedProject.self,
      Self.CachedSession.self,
      Self.CachedAgent.self,
      Self.CachedWorkItem.self,
      Self.CachedSignalRecord.self,
      Self.CachedTimelineEntry.self,
      Self.CachedObserver.self,
      Self.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
    ]
  }
}

public enum HarnessMonitorSchemaV2: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      Self.CachedProject.self,
      Self.CachedSession.self,
      Self.CachedAgent.self,
      Self.CachedWorkItem.self,
      Self.CachedSignalRecord.self,
      Self.CachedTimelineEntry.self,
      Self.CachedObserver.self,
      Self.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
    ]
  }
}

public enum HarnessMonitorSchemaV3: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      Self.CachedProject.self,
      Self.CachedSession.self,
      Self.CachedAgent.self,
      Self.CachedWorkItem.self,
      Self.CachedSignalRecord.self,
      Self.CachedTimelineEntry.self,
      Self.CachedObserver.self,
      Self.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
    ]
  }
}

public enum HarnessMonitorSchemaV4: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      Self.CachedProject.self,
      Self.CachedSession.self,
      Self.CachedAgent.self,
      Self.CachedWorkItem.self,
      Self.CachedSignalRecord.self,
      Self.CachedTimelineEntry.self,
      Self.CachedObserver.self,
      Self.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
    ]
  }
}

public enum HarnessMonitorSchemaV5: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      Self.CachedProject.self,
      Self.CachedSession.self,
      Self.CachedAgent.self,
      Self.CachedWorkItem.self,
      Self.CachedSignalRecord.self,
      Self.CachedTimelineEntry.self,
      Self.CachedObserver.self,
      Self.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
    ]
  }
}

public enum HarnessMonitorSchemaV6: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      Self.CachedProject.self,
      Self.CachedSession.self,
      Self.CachedAgent.self,
      Self.CachedWorkItem.self,
      Self.CachedSignalRecord.self,
      Self.CachedTimelineEntry.self,
      Self.CachedObserver.self,
      Self.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
    ]
  }
}

/// V7 adds the supervisor surface: `Decision`, `SupervisorEvent`, `PolicyConfigRow`. The
/// existing V6 entities are unchanged so the V6→V7 stage is lightweight. No destructive field
/// changes; three additive rows with independent lifetimes.
public enum HarnessMonitorSchemaV7: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV6.CachedProject.self,
      HarnessMonitorSchemaV6.CachedSession.self,
      HarnessMonitorSchemaV6.CachedAgent.self,
      HarnessMonitorSchemaV6.CachedWorkItem.self,
      HarnessMonitorSchemaV6.CachedSignalRecord.self,
      HarnessMonitorSchemaV6.CachedTimelineEntry.self,
      HarnessMonitorSchemaV6.CachedObserver.self,
      HarnessMonitorSchemaV6.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
    ]
  }
}

/// V8 adds a `CachedTaskReviewMetadata` side-table so the offline cache
/// can round-trip the Slice 1 review workflow (awaiting review, reviewer
/// claim, consensus, round counter, arbitration, persona hint, review
/// history). The table is keyed by `(sessionId, taskId)` with a JSON
/// `reviewBlob`, so future review-state fields stay lightweight.
public enum HarnessMonitorSchemaV8: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(8, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV6.CachedProject.self,
      HarnessMonitorSchemaV6.CachedSession.self,
      HarnessMonitorSchemaV6.CachedAgent.self,
      HarnessMonitorSchemaV6.CachedWorkItem.self,
      HarnessMonitorSchemaV6.CachedSignalRecord.self,
      HarnessMonitorSchemaV6.CachedTimelineEntry.self,
      HarnessMonitorSchemaV6.CachedObserver.self,
      HarnessMonitorSchemaV6.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      Self.CachedTaskReviewMetadata.self,
    ]
  }
}

public enum HarnessMonitorSchemaV9: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(9, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV6.CachedProject.self,
      HarnessMonitorSchemaV6.CachedSession.self,
      HarnessMonitorSchemaV6.CachedAgent.self,
      HarnessMonitorSchemaV6.CachedWorkItem.self,
      HarnessMonitorSchemaV6.CachedSignalRecord.self,
      HarnessMonitorSchemaV6.CachedTimelineEntry.self,
      HarnessMonitorSchemaV6.CachedObserver.self,
      HarnessMonitorSchemaV6.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      Self.CachedSessionWindowState.self,
    ]
  }
}

/// V10 layers tab-grouping fields onto `CachedSessionWindowState` so windows
/// that were tabbed together at quit can be re-merged at launch. The new
/// fields (`tabGroupOrdinal`, `tabPosition`, `wasForegroundTab`) are optional
/// or have safe defaults, so the V9->V10 stage is lightweight and existing
/// rows migrate without data loss.
public enum HarnessMonitorSchemaV10: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(10, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV6.CachedProject.self,
      HarnessMonitorSchemaV6.CachedSession.self,
      HarnessMonitorSchemaV6.CachedAgent.self,
      HarnessMonitorSchemaV6.CachedWorkItem.self,
      HarnessMonitorSchemaV6.CachedSignalRecord.self,
      HarnessMonitorSchemaV6.CachedTimelineEntry.self,
      HarnessMonitorSchemaV6.CachedObserver.self,
      HarnessMonitorSchemaV6.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      Self.CachedSessionWindowState.self,
    ]
  }
}

/// V11 adds `CachedSessionTranscriptEntry`, an additive side-table for normalized ACP
/// transcript rows keyed by `(sessionId, entryId)`. Existing cached sessions and
/// timelines are unchanged, so the V10->V11 stage remains lightweight.
public enum HarnessMonitorSchemaV11: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(11, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV6.CachedProject.self,
      HarnessMonitorSchemaV6.CachedSession.self,
      HarnessMonitorSchemaV6.CachedAgent.self,
      HarnessMonitorSchemaV6.CachedWorkItem.self,
      HarnessMonitorSchemaV6.CachedSignalRecord.self,
      HarnessMonitorSchemaV6.CachedTimelineEntry.self,
      HarnessMonitorSchemaV6.CachedObserver.self,
      HarnessMonitorSchemaV6.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      Self.CachedSessionTranscriptEntry.self,
    ]
  }
}

/// V12 keeps the V11 transcript side-table and adds `sourceRaw` provenance so cached
/// transcript rows retain whether they came from the dedicated ACP transcript feed or
/// from timeline-derived fallback reconstruction.
public enum HarnessMonitorSchemaV12: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(12, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV6.CachedProject.self,
      HarnessMonitorSchemaV6.CachedSession.self,
      HarnessMonitorSchemaV6.CachedAgent.self,
      HarnessMonitorSchemaV6.CachedWorkItem.self,
      HarnessMonitorSchemaV6.CachedSignalRecord.self,
      HarnessMonitorSchemaV6.CachedTimelineEntry.self,
      HarnessMonitorSchemaV6.CachedObserver.self,
      HarnessMonitorSchemaV6.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      Self.CachedSessionTranscriptEntry.self,
    ]
  }
}

/// Historical V13 adds a `CachedAgentManagedMetadata` side-table so cached
/// session detail can retain managed-agent identity without rebasing the whole
/// cached graph. Keep this exact schema available because stores created by the
/// earlier V13 build must still be recognized by staged migration.
public enum HarnessMonitorSchemaV13: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(13, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV6.CachedProject.self,
      HarnessMonitorSchemaV6.CachedSession.self,
      HarnessMonitorSchemaV6.CachedAgent.self,
      HarnessMonitorSchemaV6.CachedWorkItem.self,
      HarnessMonitorSchemaV6.CachedSignalRecord.self,
      HarnessMonitorSchemaV6.CachedTimelineEntry.self,
      HarnessMonitorSchemaV6.CachedObserver.self,
      HarnessMonitorSchemaV6.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
      Self.CachedAgentManagedMetadata.self,
    ]
  }
}

/// V14 rebases the cached session graph onto a new schema generation so
/// `CachedAgent` can persist managed-agent identity directly via
/// `managedAgentID` / `managedAgentKindRaw`. The relationship graph is
/// otherwise unchanged, so the V13->V14 migration stays lightweight.
public enum HarnessMonitorSchemaV14: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(14, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      Self.CachedProject.self,
      Self.CachedSession.self,
      Self.CachedAgent.self,
      Self.CachedWorkItem.self,
      Self.CachedSignalRecord.self,
      Self.CachedTimelineEntry.self,
      Self.CachedObserver.self,
      Self.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
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
}

public typealias HarnessMonitorCurrentSchema = HarnessMonitorSchemaV14
