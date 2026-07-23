import Foundation
import SwiftData

@Model
public final class SessionBookmark {
  #Unique<SessionBookmark>([\.sessionId])
  #Index<SessionBookmark>([\.sessionId], [\.projectId])

  public var sessionId: String
  public var projectId: String
  public var createdAt: Date
  public var label: String?

  public init(sessionId: String, projectId: String, createdAt: Date = .now, label: String? = nil) {
    self.sessionId = sessionId
    self.projectId = projectId
    self.createdAt = createdAt
    self.label = label
  }
}

@Model
public final class UserNote {
  #Index<UserNote>([\.targetId], [\.sessionId])

  public var targetKind: String
  public var targetId: String
  public var sessionId: String
  public var text: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    targetKind: String,
    targetId: String,
    sessionId: String,
    text: String,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.targetKind = targetKind
    self.targetId = targetId
    self.sessionId = sessionId
    self.text = text
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

@Model
public final class RecentSearch {
  #Unique<RecentSearch>([\.query])
  #Index<RecentSearch>([\.lastUsedAt])

  public var query: String
  public var lastUsedAt: Date
  public var useCount: Int

  public init(query: String, lastUsedAt: Date = .now, useCount: Int = 1) {
    self.query = query
    self.lastUsedAt = lastUsedAt
    self.useCount = useCount
  }
}

@Model
public final class ProjectFilterPreference {
  #Unique<ProjectFilterPreference>([\.projectId])
  #Index<ProjectFilterPreference>([\.projectId])

  public var projectId: String
  public var sessionFilterRaw: String
  public var sessionFocusFilterRaw: String

  public init(projectId: String, sessionFilterRaw: String, sessionFocusFilterRaw: String) {
    self.projectId = projectId
    self.sessionFilterRaw = sessionFilterRaw
    self.sessionFocusFilterRaw = sessionFocusFilterRaw
  }
}

@Model
public final class NotificationHistoryRecord {
  #Unique<NotificationHistoryRecord>([\.entryID])
  #Index<NotificationHistoryRecord>([\.recordedAt], [\.updatedAt], [\.sourceRaw])

  public var entryID: String
  public var sourceRaw: String
  public var recordedAt: Date
  public var updatedAt: Date
  public var dropsOnRelaunch: Bool
  public var snapshotData: Data

  public init(
    entryID: String,
    sourceRaw: String,
    recordedAt: Date,
    updatedAt: Date,
    dropsOnRelaunch: Bool,
    snapshotData: Data
  ) {
    self.entryID = entryID
    self.sourceRaw = sourceRaw
    self.recordedAt = recordedAt
    self.updatedAt = updatedAt
    self.dropsOnRelaunch = dropsOnRelaunch
    self.snapshotData = snapshotData
  }
}

extension NotificationHistoryRecord {
  static func make(from entry: NotificationHistoryEntry) throws -> NotificationHistoryRecord {
    NotificationHistoryRecord(
      entryID: entry.id,
      sourceRaw: entry.source.rawValue,
      recordedAt: entry.recordedAt,
      updatedAt: entry.updatedAt,
      dropsOnRelaunch: entry.dropsOnRelaunch,
      snapshotData: try Codecs.encoder.encode(entry)
    )
  }

  func update(from entry: NotificationHistoryEntry) throws {
    sourceRaw = entry.source.rawValue
    recordedAt = entry.recordedAt
    updatedAt = entry.updatedAt
    dropsOnRelaunch = entry.dropsOnRelaunch
    snapshotData = try Codecs.encoder.encode(entry)
  }

  func decodedEntry() throws -> NotificationHistoryEntry {
    try Codecs.decoder.decode(NotificationHistoryEntry.self, from: snapshotData)
  }
}

@Model
public final class AuditEventRecord {
  #Unique<AuditEventRecord>([\.dedupeKey])
  #Index<AuditEventRecord>(
    [\.recordedAt],
    [\.sourceRaw],
    [\.categoryRaw],
    [\.severityRaw],
    [\.outcomeRaw],
    [\.actionKey],
    [\.subject]
  )

  public var dedupeKey: String
  public var eventID: String
  public var recordedAt: Date
  public var sourceRaw: String
  public var categoryRaw: String
  public var severityRaw: String
  public var outcomeRaw: String
  public var actionKey: String?
  public var subject: String?
  public var snapshotData: Data

  public init(
    dedupeKey: String,
    eventID: String,
    recordedAt: Date,
    sourceRaw: String,
    categoryRaw: String,
    severityRaw: String,
    outcomeRaw: String,
    actionKey: String?,
    subject: String?,
    snapshotData: Data
  ) {
    self.dedupeKey = dedupeKey
    self.eventID = eventID
    self.recordedAt = recordedAt
    self.sourceRaw = sourceRaw
    self.categoryRaw = categoryRaw
    self.severityRaw = severityRaw
    self.outcomeRaw = outcomeRaw
    self.actionKey = actionKey
    self.subject = subject
    self.snapshotData = snapshotData
  }
}

extension AuditEventRecord {
  static func make(from event: HarnessMonitorAuditEvent) throws -> AuditEventRecord {
    AuditEventRecord(
      dedupeKey: event.dedupeKey,
      eventID: event.id,
      recordedAt: event.recordedAt,
      sourceRaw: event.source,
      categoryRaw: event.category,
      severityRaw: event.severity,
      outcomeRaw: event.outcome,
      actionKey: event.actionKey,
      subject: event.subject,
      snapshotData: try Codecs.encoder.encode(event)
    )
  }

  func update(from event: HarnessMonitorAuditEvent) throws {
    eventID = event.id
    recordedAt = event.recordedAt
    sourceRaw = event.source
    categoryRaw = event.category
    severityRaw = event.severity
    outcomeRaw = event.outcome
    actionKey = event.actionKey
    subject = event.subject
    snapshotData = try Codecs.encoder.encode(event)
  }

  func decodedEvent() throws -> HarnessMonitorAuditEvent {
    try Codecs.decoder.decode(HarnessMonitorAuditEvent.self, from: snapshotData)
  }
}

@Model
public final class CachedTaskBoardSnapshot {
  #Unique<CachedTaskBoardSnapshot>([\.snapshotID])
  #Index<CachedTaskBoardSnapshot>([\.cachedAt])

  public var snapshotID: String
  public var cachedAt: Date
  public var itemsData: Data
  public var orchestratorStatusData: Data

  public init(
    snapshotID: String = "global-task-board",
    cachedAt: Date = .now,
    itemsData: Data = Data(),
    orchestratorStatusData: Data = Data()
  ) {
    self.snapshotID = snapshotID
    self.cachedAt = cachedAt
    self.itemsData = itemsData
    self.orchestratorStatusData = orchestratorStatusData
  }
}

extension CachedTaskBoardSnapshot {
  public static var globalSnapshotID: String {
    "global-task-board"
  }

  static func make(
    items: [TaskBoardItem],
    orchestratorStatus: TaskBoardOrchestratorStatus?
  ) throws -> CachedTaskBoardSnapshot {
    try CachedTaskBoardSnapshot(
      itemsData: Codecs.encoder.encode(items),
      orchestratorStatusData: encodedOrchestratorStatus(orchestratorStatus)
    )
  }

  func update(
    items: [TaskBoardItem],
    orchestratorStatus: TaskBoardOrchestratorStatus?
  ) throws {
    cachedAt = .now
    itemsData = try Codecs.encoder.encode(items)
    orchestratorStatusData = try encodedOrchestratorStatus(orchestratorStatus)
  }

  func decodedItems() throws -> [TaskBoardItem] {
    guard !itemsData.isEmpty else {
      return []
    }
    return try Codecs.decoder.decode([TaskBoardItem].self, from: itemsData)
  }

  func decodedOrchestratorStatus() throws -> TaskBoardOrchestratorStatus? {
    guard !orchestratorStatusData.isEmpty else {
      return nil
    }
    return try Codecs.decoder.decode(
      TaskBoardOrchestratorStatus.self,
      from: orchestratorStatusData
    )
  }
}

private func encodedOrchestratorStatus(
  _ orchestratorStatus: TaskBoardOrchestratorStatus?
) throws -> Data {
  guard let orchestratorStatus else {
    return Data()
  }
  return try Codecs.encoder.encode(orchestratorStatus.withoutAutomationSnapshot)
}

@Model
public final class CachedReviewsSnapshot {
  #Unique<CachedReviewsSnapshot>([\.preferencesHash])
  #Index<CachedReviewsSnapshot>([\.cachedAt])

  public var preferencesHash: String
  public var cachedAt: Date
  public var responseData: Data

  public init(
    preferencesHash: String,
    cachedAt: Date = .now,
    responseData: Data = Data()
  ) {
    self.preferencesHash = preferencesHash
    self.cachedAt = cachedAt
    self.responseData = responseData
  }
}

extension CachedReviewsSnapshot {
  static func make(
    preferencesHash: String,
    response: ReviewsQueryResponse
  ) throws -> CachedReviewsSnapshot {
    try CachedReviewsSnapshot(
      preferencesHash: preferencesHash,
      responseData: Codecs.encoder.encode(response)
    )
  }

  func update(response: ReviewsQueryResponse) throws {
    cachedAt = .now
    responseData = try Codecs.encoder.encode(response)
  }

  func decodedResponse() throws -> ReviewsQueryResponse? {
    guard !responseData.isEmpty else {
      return nil
    }
    return try Codecs.decoder.decode(
      ReviewsQueryResponse.self,
      from: responseData
    )
  }
}

@Model
public final class CachedTaskBoardPolicyDocument {
  #Unique<CachedTaskBoardPolicyDocument>([\.canvasId])
  #Index<CachedTaskBoardPolicyDocument>([\.cachedAt])

  public var canvasId: String
  public var cachedAt: Date
  public var documentData: Data

  public init(canvasId: String, cachedAt: Date = .now, documentData: Data) {
    self.canvasId = canvasId
    self.cachedAt = cachedAt
    self.documentData = documentData
  }
}

/// Code-facing alias for the policy document cache. The underlying model class
/// keeps its historical name because SwiftData uses `@Model` class names for
/// persistent entity identity in existing V24/V25 stores.
public typealias CachedPolicyDocument = CachedTaskBoardPolicyDocument

extension CachedTaskBoardPolicyDocument {
  func decodedDocument() throws -> PolicyPipelineDocument {
    try Codecs.decoder.decode(PolicyPipelineDocument.self, from: documentData)
  }
}
