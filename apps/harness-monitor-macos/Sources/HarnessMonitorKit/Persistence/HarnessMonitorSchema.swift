import SwiftData

public enum HarnessMonitorSchemaV1: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      CachedProject.self,
      CachedSession.self,
      CachedAgent.self,
      CachedWorkItem.self,
      CachedSignalRecord.self,
      CachedTimelineEntry.self,
      CachedObserver.self,
      CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
    ]
  }
}

public enum HarnessMonitorMigrationPlan: SchemaMigrationPlan {
  public static var schemas: [any VersionedSchema.Type] {
    [HarnessMonitorSchemaV1.self]
  }

  public static var stages: [MigrationStage] {
    []
  }
}
