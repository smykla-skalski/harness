import SwiftData

/// V24 is purely additive: one policy document cache table keyed by canvas
/// ID, with no relationships into the existing V23 graph. Lightweight
/// migration adds the empty table; the store write-through fills it on the
/// next canvas refresh.
public enum HarnessMonitorSchemaV24: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(24, 0, 0) }

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
