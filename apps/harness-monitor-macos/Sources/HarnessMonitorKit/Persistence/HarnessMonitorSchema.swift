import Foundation
import SwiftData

public enum HarnessMonitorSchemaV1: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV1.CachedProject.self,
      HarnessMonitorSchemaV1.CachedSession.self,
      HarnessMonitorSchemaV1.CachedAgent.self,
      HarnessMonitorSchemaV1.CachedWorkItem.self,
      HarnessMonitorSchemaV1.CachedSignalRecord.self,
      HarnessMonitorSchemaV1.CachedTimelineEntry.self,
      HarnessMonitorSchemaV1.CachedObserver.self,
      HarnessMonitorSchemaV1.CachedAgentActivity.self,
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
      HarnessMonitorSchemaV2.CachedProject.self,
      HarnessMonitorSchemaV2.CachedSession.self,
      HarnessMonitorSchemaV2.CachedAgent.self,
      HarnessMonitorSchemaV2.CachedWorkItem.self,
      HarnessMonitorSchemaV2.CachedSignalRecord.self,
      HarnessMonitorSchemaV2.CachedTimelineEntry.self,
      HarnessMonitorSchemaV2.CachedObserver.self,
      HarnessMonitorSchemaV2.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
    ]
  }
}

public enum HarnessMonitorMigrationPlan: SchemaMigrationPlan {
  public static var schemas: [any VersionedSchema.Type] {
    [HarnessMonitorSchemaV1.self, HarnessMonitorSchemaV2.self]
  }

  public static var stages: [MigrationStage] {
    [migrateV1toV2]
  }

  static let migrateV1toV2 = MigrationStage.custom(
    fromVersion: HarnessMonitorSchemaV1.self,
    toVersion: HarnessMonitorSchemaV2.self,
    willMigrate: nil,
    didMigrate: { context in
      let projects = try context.fetch(FetchDescriptor<HarnessMonitorSchemaV2.CachedProject>())
      for project in projects {
        project.worktreesData = Data()
      }

      let sessions = try context.fetch(FetchDescriptor<HarnessMonitorSchemaV2.CachedSession>())
      for session in sessions {
        session.checkoutId = session.projectId
        session.checkoutRoot = session.projectDir ?? session.contextRoot
        session.isWorktree = false
        session.worktreeName = nil
      }

      try context.save()
    }
  )
}
