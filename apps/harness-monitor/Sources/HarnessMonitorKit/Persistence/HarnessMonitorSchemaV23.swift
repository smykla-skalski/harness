import SwiftData

/// V23 is purely additive: review timeline avatars persist as raw image
/// bytes in `CachedReviewAvatar`, keyed by GitHub's exact `avatarUrl`.
/// Existing review/session/cache rows are untouched, so lightweight
/// migration is sufficient.
public enum HarnessMonitorSchemaV23: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(23, 0, 0) }

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
    ]
  }
}
