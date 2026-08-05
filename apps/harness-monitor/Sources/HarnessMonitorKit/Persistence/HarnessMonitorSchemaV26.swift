import SwiftData

/// V26 retires `CachedSessionWindowState`. Session windows remain available
/// during the staged UI removal, but launch restoration no longer persists or
/// consumes their identities. Every unrelated cache and user-data entity keeps
/// its V25 model type so lightweight migration preserves those rows.
public enum HarnessMonitorSchemaV26: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(26, 0, 0) }

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
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
      CachedPolicyDocument.self,
    ]
  }
}
