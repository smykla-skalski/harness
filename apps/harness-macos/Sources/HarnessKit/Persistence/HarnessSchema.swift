import SwiftData

public enum HarnessSchemaV1: VersionedSchema {
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

public enum HarnessMigrationPlan: SchemaMigrationPlan {
  public static var schemas: [any VersionedSchema.Type] {
    [HarnessSchemaV1.self]
  }

  public static var stages: [MigrationStage] {
    []
  }
}
