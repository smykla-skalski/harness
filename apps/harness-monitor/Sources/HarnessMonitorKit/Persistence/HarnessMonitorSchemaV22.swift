import SwiftData

/// V22 mirrors V21 in shape but replaces the seven historical
/// `CachedDependency*` entity classes introduced across V17–V21 with the
/// renamed `CachedReview*` equivalents. SwiftData treats the class-name
/// change as a different entity, so the V21→V22 transition is a custom
/// migration (`HarnessMonitorMigrationV21ToV22.stage`) that fetches each
/// old entity, inserts an equivalent new entity, and deletes the source
/// row. Every other entity in the schema is unchanged.
public enum HarnessMonitorSchemaV22: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(22, 0, 0) }

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
      CachedReviewsSnapshot.self,
      CachedReviewRepositoryLabels.self,
      CachedReviewLabelUsage.self,
      CachedReviewsRepoSyncState.self,
      CachedReviewFilesSummary.self,
      CachedReviewFile.self,
      CachedReviewFileViewedState.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
    ]
  }
}
