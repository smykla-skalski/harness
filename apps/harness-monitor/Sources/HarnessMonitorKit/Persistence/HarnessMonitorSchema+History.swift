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

public enum HarnessMonitorSchemaV5: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

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

public enum HarnessMonitorSchemaV6: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }

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

/// V7 adds the supervisor surface: `Decision`, `SupervisorEvent`, `PolicyConfigRow`. The
/// existing V6 entities are unchanged so the V6→V7 stage is lightweight. No destructive field
/// changes; three additive rows with independent lifetimes.
public enum HarnessMonitorSchemaV7: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }

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
    ]
  }
}

/// V8 adds a `CachedTaskReviewMetadata` side-table so the offline cache
/// can round-trip the Slice 1 review workflow (awaiting review, reviewer
/// claim, consensus, round counter, arbitration, persona hint, review
/// history). The table is keyed by `(sessionId, taskId)` with a JSON
/// `reviewBlob`, so future review-state fields stay lightweight.
public enum HarnessMonitorSchemaV8: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(8, 0, 0) }

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
      Self.CachedTaskReviewMetadata.self,
    ]
  }
}

public enum HarnessMonitorSchemaV9: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(9, 0, 0) }

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
      Self.CachedSessionWindowState.self,
    ]
  }
}

/// V10 layers tab-grouping fields onto `CachedSessionWindowState` so windows
/// that were tabbed together at quit can be re-merged at launch. The new
/// fields (`tabGroupOrdinal`, `tabPosition`, `wasForegroundTab`) are optional
/// or have safe defaults, so the V9->V10 stage is lightweight and existing
/// rows migrate without data loss.
public enum HarnessMonitorSchemaV10: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(10, 0, 0) }

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
      Self.CachedSessionWindowState.self,
    ]
  }
}

/// V11 adds `CachedSessionTranscriptEntry`, an additive side-table for normalized ACP
/// transcript rows keyed by `(sessionId, entryId)`. Existing cached sessions and
/// timelines are unchanged, so the V10->V11 stage remains lightweight.
public enum HarnessMonitorSchemaV11: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(11, 0, 0) }

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
      Self.CachedSessionTranscriptEntry.self,
    ]
  }
}

/// V12 keeps the V11 transcript side-table and adds `sourceRaw` provenance so cached
/// transcript rows retain whether they came from the dedicated ACP transcript feed or
/// from timeline-derived fallback reconstruction.
public enum HarnessMonitorSchemaV12: VersionedSchema {
  public static var versionIdentifier: Schema.Version { Schema.Version(12, 0, 0) }

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
      Self.CachedSessionTranscriptEntry.self,
    ]
  }
}
