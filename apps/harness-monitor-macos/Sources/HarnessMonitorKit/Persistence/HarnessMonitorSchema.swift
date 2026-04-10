import Foundation
import SwiftData

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

  public static var versionString: String {
    let version = versionIdentifier
    return "\(version.major).\(version.minor).\(version.patch)"
  }

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

  public static var versionString: String {
    let version = versionIdentifier
    return "\(version.major).\(version.minor).\(version.patch)"
  }

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
    ]
  }

  public static var stages: [MigrationStage] {
    [migrateV1toV2, migrateV2toV3, migrateV3toV4]
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

  static let migrateV2toV3 = MigrationStage.custom(
    fromVersion: HarnessMonitorSchemaV2.self,
    toVersion: HarnessMonitorSchemaV3.self,
    willMigrate: nil,
    didMigrate: { context in
      let sessions = try context.fetch(FetchDescriptor<HarnessMonitorSchemaV3.CachedSession>())
      for session in sessions {
        session.title = ""
      }

      try context.save()
    }
  )

  static let migrateV3toV4 = MigrationStage.lightweight(
    fromVersion: HarnessMonitorSchemaV3.self,
    toVersion: HarnessMonitorSchemaV4.self
  )
}
