import SwiftData

/// V21 is purely additive: three new entities for the Dependencies > Files
/// per-PR file cache. `CachedDependencyUpdateFilesSummary` keys by
/// `pullRequestID` (one row per PR); `CachedDependencyUpdateFile` and
/// `CachedDependencyUpdateFileViewedState` use a compound `pullRequestID +
/// headRefOid + path` key so a force-push that flips `headRefOid` writes a
/// fresh row set without colliding with the prior state. Lightweight
/// migration adds the empty tables; the dashboard repopulates them on the
/// next `list_dependency_update_files` round-trip.
public enum HarnessMonitorSchemaV21: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(21, 0, 0) }

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
      CachedDependencyUpdatesSnapshot.self,
      CachedDependencyRepositoryLabels.self,
      CachedDependencyLabelUsage.self,
      CachedDependencyUpdatesRepoSyncState.self,
      CachedDependencyUpdateFilesSummary.self,
      CachedDependencyUpdateFile.self,
      CachedDependencyUpdateFileViewedState.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
    ]
  }
}
