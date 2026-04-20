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

public enum HarnessMonitorMigrationPlan: SchemaMigrationPlan {
  public static var schemas: [any VersionedSchema.Type] {
    [
      HarnessMonitorSchemaV1.self,
      HarnessMonitorSchemaV2.self,
      HarnessMonitorSchemaV3.self,
      HarnessMonitorSchemaV4.self,
      HarnessMonitorSchemaV5.self,
      HarnessMonitorSchemaV6.self,
    ]
  }

  public static var stages: [MigrationStage] {
    [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6]
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

  static let migrateV5toV6 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV5.self,
    toVersion: HarnessMonitorSchemaV6.self
  )
}

public typealias HarnessMonitorCurrentSchema = HarnessMonitorSchemaV6
