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
}

public typealias HarnessMonitorCurrentSchema = HarnessMonitorSchemaV8
