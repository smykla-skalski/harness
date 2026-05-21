import SwiftData

extension VersionedSchema {
  public static var versionString: String {
    let version = versionIdentifier
    return "\(version.major).\(version.minor).\(version.patch)"
  }
}

/// Historical V13 adds a `CachedAgentManagedMetadata` side-table so cached
/// session detail can retain managed-agent identity without rebasing the whole
/// cached graph. Keep this exact schema available because stores created by the
/// earlier V13 build must still be recognized by staged migration.
public enum HarnessMonitorSchemaV13: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(13, 0, 0) }

  public static var models: [any PersistentModel.Type] {
    [
      HarnessMonitorSchemaV6.CachedProject.self,
      HarnessMonitorSchemaV6.CachedSession.self,
      HarnessMonitorSchemaV6.CachedAgent.self,
      HarnessMonitorSchemaV6.CachedWorkItem.self,
      HarnessMonitorSchemaV6.CachedSignalRecord.self,
      HarnessMonitorSchemaV6.CachedTimelineEntry.self,
      HarnessMonitorSchemaV6.CachedObserver.self,
      HarnessMonitorSchemaV6.CachedAgentActivity.self,
      SessionBookmark.self,
      UserNote.self,
      RecentSearch.self,
      ProjectFilterPreference.self,
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
      Self.CachedAgentManagedMetadata.self,
    ]
  }
}

/// V14 rebases the cached session graph onto a new schema generation so
/// `CachedAgent` can persist managed-agent identity directly via
/// `managedAgentID` / `managedAgentKindRaw`. The relationship graph is
/// otherwise unchanged, so the V13->V14 migration stays lightweight.
public enum HarnessMonitorSchemaV14: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(14, 0, 0) }

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
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
    ]
  }
}

/// V15 is purely additive: notification history rows persist app-global toast/system
/// notification history in their own table keyed by `entryID`. Existing user/cache rows
/// are untouched, so lightweight migration is correct.
public enum HarnessMonitorSchemaV15: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(15, 0, 0) }

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
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
    ]
  }
}

/// V16 is purely additive: task-board items and orchestrator status persist in a
/// single app-global snapshot row keyed by `snapshotID`. Existing user/cache rows
/// remain untouched, so lightweight migration is correct.
public enum HarnessMonitorSchemaV16: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(16, 0, 0) }

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
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
    ]
  }
}

/// V17 is purely additive: dependency-update query responses persist as one
/// row per normalized-preferences hash so cold starts can hydrate the dashboard
/// route before the daemon round-trip completes. Existing rows are untouched,
/// so lightweight migration is correct.
public enum HarnessMonitorSchemaV17: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(17, 0, 0) }

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
      Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      HarnessMonitorSchemaV8.CachedTaskReviewMetadata.self,
      HarnessMonitorSchemaV10.CachedSessionWindowState.self,
      HarnessMonitorSchemaV12.CachedSessionTranscriptEntry.self,
    ]
  }
}
