import SwiftData

/// V25 is additive: one app-wide audit read-model table keyed by `dedupeKey`.
/// Notification, supervisor, daemon, and future typed daemon audit sources
/// upsert into this table without changing the existing source tables.
public enum HarnessMonitorSchemaV25: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(25, 0, 0) }

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
      AuditEventRecord.self,
      CachedTaskBoardSnapshot.self,
      CachedReviewsSnapshot.self,
      CachedReviewRepositoryLabels.self,
      CachedReviewLabelUsage.self,
      CachedReviewsRepoSyncState.self,
      CachedReviewFilesSummary.self,
      CachedReviewFile.self,
      CachedReviewFileViewedState.self,
      CachedReviewAvatar.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
      CachedPolicyDocument.self,
    ]
  }
}
