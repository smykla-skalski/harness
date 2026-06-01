import Foundation
import SwiftData
import os

public actor UserDataPersistenceService {
  public struct RecordCounts: Sendable {
    public let bookmarks: Int
    public let notes: Int
    public let searches: Int
    public let filterPreferences: Int
    public let notifications: Int
    public let auditEvents: Int

    public static let zero = RecordCounts(
      bookmarks: 0,
      notes: 0,
      searches: 0,
      filterPreferences: 0,
      notifications: 0,
      auditEvents: 0
    )
  }

  public struct FilterPreference: Equatable, Sendable {
    public let sessionFilterRaw: String
    public let sessionFocusFilterRaw: String
  }

  public struct UserNoteIdentity: @unchecked Sendable {
    let persistentID: PersistentIdentifier

    public init(_ note: UserNote) {
      self.persistentID = note.persistentModelID
    }
  }

  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "persistence"
  )
  private static let maxAuditEventCacheRecords = 1_000

  private let modelContainer: ModelContainer
  private let maxRecentSearches: Int
  private let saveChanges: @Sendable (ModelContext) throws -> Void

  public init(
    modelContainer: ModelContainer,
    maxRecentSearches: Int,
    saveChanges: @escaping @Sendable (ModelContext) throws -> Void = { context in
      try context.save()
    }
  ) {
    self.modelContainer = modelContainer
    self.maxRecentSearches = maxRecentSearches
    self.saveChanges = saveChanges
  }

  public func bookmarkIDs() throws -> Set<String> {
    try withPersistenceSignpost("user_data.bookmarks.fetch") {
      let context = makeContext()
      let bookmarks = try context.fetch(FetchDescriptor<SessionBookmark>())
      return Set(bookmarks.map(\.sessionId))
    }
  }

  @discardableResult
  public func toggleBookmark(sessionId: String, projectId: String) throws -> Bool {
    try withPersistenceSignpost("user_data.bookmark.toggle") {
      let context = makeContext()
      var descriptor = FetchDescriptor<SessionBookmark>(
        predicate: #Predicate { $0.sessionId == sessionId }
      )
      descriptor.fetchLimit = 1

      let isAddingBookmark: Bool
      if let existing = try context.fetch(descriptor).first {
        context.delete(existing)
        isAddingBookmark = false
      } else {
        context.insert(SessionBookmark(sessionId: sessionId, projectId: projectId))
        isAddingBookmark = true
      }

      try saveChanges(context)
      return isAddingBookmark
    }
  }

  public func addNote(
    text: String,
    targetKind: String,
    targetId: String,
    sessionId: String
  ) throws {
    try withPersistenceSignpost("user_data.note.add") {
      let context = makeContext()
      context.insert(
        UserNote(
          targetKind: targetKind,
          targetId: targetId,
          sessionId: sessionId,
          text: text
        )
      )
      try saveChanges(context)
    }
  }

  @discardableResult
  public func deleteNote(_ identity: UserNoteIdentity) throws -> Bool {
    try withPersistenceSignpost("user_data.note.delete") {
      let context = makeContext()
      guard let note = context.model(for: identity.persistentID) as? UserNote else {
        return false
      }
      context.delete(note)
      try saveChanges(context)
      return true
    }
  }

  @discardableResult
  public func recordSearch(_ query: String) throws -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    return try withPersistenceSignpost("user_data.search.record") {
      let context = makeContext()
      var descriptor = FetchDescriptor<RecentSearch>(
        predicate: #Predicate { $0.query == trimmed }
      )
      descriptor.fetchLimit = 1

      if let existing = try context.fetch(descriptor).first {
        existing.lastUsedAt = .now
        existing.useCount += 1
      } else {
        context.insert(RecentSearch(query: trimmed))
      }

      try saveChanges(context)
      try evictOldSearches(in: context)
      return true
    }
  }

  public func clearSearchHistory() throws {
    try withPersistenceSignpost("user_data.search.clear") {
      let context = makeContext()
      let searches = try context.fetch(FetchDescriptor<RecentSearch>())
      for search in searches {
        context.delete(search)
      }
      try saveChanges(context)
    }
  }

  public func saveFilterPreference(
    projectId: String,
    sessionFilterRaw: String,
    sessionFocusFilterRaw: String
  ) throws {
    try withPersistenceSignpost("user_data.filter.save") {
      let context = makeContext()
      var descriptor = FetchDescriptor<ProjectFilterPreference>(
        predicate: #Predicate { $0.projectId == projectId }
      )
      descriptor.fetchLimit = 1

      if let existing = try context.fetch(descriptor).first {
        existing.sessionFilterRaw = sessionFilterRaw
        existing.sessionFocusFilterRaw = sessionFocusFilterRaw
      } else {
        context.insert(
          ProjectFilterPreference(
            projectId: projectId,
            sessionFilterRaw: sessionFilterRaw,
            sessionFocusFilterRaw: sessionFocusFilterRaw
          )
        )
      }

      try saveChanges(context)
    }
  }

  public func loadFilterPreference(projectId: String) throws -> FilterPreference? {
    try withPersistenceSignpost("user_data.filter.load") {
      let context = makeContext()
      var descriptor = FetchDescriptor<ProjectFilterPreference>(
        predicate: #Predicate { $0.projectId == projectId }
      )
      descriptor.fetchLimit = 1

      guard let preference = try context.fetch(descriptor).first else {
        return nil
      }
      return FilterPreference(
        sessionFilterRaw: preference.sessionFilterRaw,
        sessionFocusFilterRaw: preference.sessionFocusFilterRaw
      )
    }
  }

  public func loadNotificationHistory() throws -> [NotificationHistoryEntry] {
    try withPersistenceSignpost("user_data.notifications.fetch") {
      let context = makeContext()
      let records = try context.fetch(
        FetchDescriptor<NotificationHistoryRecord>(
          sortBy: [
            SortDescriptor(\.recordedAt, order: .reverse),
            SortDescriptor(\.updatedAt, order: .reverse),
          ]
        ))
      var entries: [NotificationHistoryEntry] = []
      var invalidRecords: [NotificationHistoryRecord] = []
      entries.reserveCapacity(records.count)
      for record in records {
        do {
          entries.append(try record.decodedEntry())
        } catch {
          invalidRecords.append(record)
          let entryID = record.entryID
          let message = error.localizedDescription
          HarnessMonitorLogger.store.warning(
            "notification decode failed entry=\(entryID, privacy: .public) error=\(message, privacy: .public)"
          )
        }
      }
      if !invalidRecords.isEmpty {
        for record in invalidRecords {
          context.delete(record)
        }
        try saveChanges(context)
      }
      return entries
    }
  }

  public func upsertNotificationHistory(_ entry: NotificationHistoryEntry) throws {
    try withPersistenceSignpost("user_data.notifications.upsert") {
      let context = makeContext()
      let entryID = entry.id
      var descriptor = FetchDescriptor<NotificationHistoryRecord>(
        predicate: #Predicate { $0.entryID == entryID }
      )
      descriptor.fetchLimit = 1
      if let existing = try context.fetch(descriptor).first {
        try existing.update(from: entry)
      } else {
        context.insert(try NotificationHistoryRecord.make(from: entry))
      }
      try saveChanges(context)
    }
  }

  public func loadAuditEvents(limit: Int = 500) throws -> [HarnessMonitorAuditEvent] {
    try withPersistenceSignpost("user_data.audit_events.fetch") {
      let context = makeContext()
      var descriptor = FetchDescriptor<AuditEventRecord>(
        sortBy: [
          SortDescriptor(\.recordedAt, order: .reverse),
          SortDescriptor(\.eventID, order: .forward),
        ]
      )
      descriptor.fetchLimit = limit
      let records = try context.fetch(descriptor)
      var events: [HarnessMonitorAuditEvent] = []
      var invalidRecords: [AuditEventRecord] = []
      events.reserveCapacity(records.count)
      for record in records {
        do {
          events.append(try record.decodedEvent())
        } catch {
          invalidRecords.append(record)
          let dedupeKey = record.dedupeKey
          let message = error.localizedDescription
          HarnessMonitorLogger.store.warning(
            "audit event decode failed key=\(dedupeKey, privacy: .public) error=\(message, privacy: .public)"
          )
        }
      }
      if !invalidRecords.isEmpty {
        for record in invalidRecords {
          context.delete(record)
        }
        try saveChanges(context)
      }
      return events.sorted(by: HarnessMonitorAuditEvent.auditEventSort)
    }
  }

  public func upsertAuditEvents(_ events: [HarnessMonitorAuditEvent]) throws {
    try withPersistenceSignpost("user_data.audit_events.upsert") {
      let context = makeContext()
      for event in events {
        let dedupeKey = event.dedupeKey
        var descriptor = FetchDescriptor<AuditEventRecord>(
          predicate: #Predicate { $0.dedupeKey == dedupeKey }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
          try existing.update(from: event)
        } else {
          context.insert(try AuditEventRecord.make(from: event))
        }
      }
      try pruneAuditEvents(
        context: context,
        maximumCount: Self.maxAuditEventCacheRecords
      )
      try saveChanges(context)
    }
  }

  private func pruneAuditEvents(context: ModelContext, maximumCount: Int) throws {
    let descriptor = FetchDescriptor<AuditEventRecord>(
      sortBy: [
        SortDescriptor(\.recordedAt, order: .reverse),
        SortDescriptor(\.eventID, order: .forward),
      ]
    )
    let records = try context.fetch(descriptor)
    guard maximumCount > 0 else {
      for record in records {
        context.delete(record)
      }
      return
    }
    guard records.count > maximumCount else {
      return
    }
    for record in records.dropFirst(maximumCount) {
      context.delete(record)
    }
  }

  @discardableResult
  public func purgeNonRestorableNotificationHistory() throws -> Int {
    try withPersistenceSignpost("user_data.notifications.purge_non_restorable") {
      let context = makeContext()
      let records = try context.fetch(
        FetchDescriptor<NotificationHistoryRecord>(
          predicate: #Predicate { $0.dropsOnRelaunch == true }
        ))
      guard !records.isEmpty else {
        return 0
      }
      for record in records {
        context.delete(record)
      }
      try saveChanges(context)
      return records.count
    }
  }

  public func taskUserNoteCount(taskID: String, sessionID: String) throws -> Int {
    try withPersistenceSignpost("user_data.task_notes.count") {
      let context = makeContext()
      return try context.fetch(taskUserNoteDescriptor(taskID: taskID, sessionID: sessionID)).count
    }
  }

  @discardableResult
  public func deleteTaskUserNotes(taskID: String, sessionID: String) throws -> Int {
    try withPersistenceSignpost("user_data.task_notes.delete") {
      let context = makeContext()
      let notes = try context.fetch(taskUserNoteDescriptor(taskID: taskID, sessionID: sessionID))
      for note in notes {
        context.delete(note)
      }
      try saveChanges(context)
      return notes.count
    }
  }

  public func recordCounts() -> RecordCounts {
    withPersistenceSignpost("user_data.record_counts") {
      let context = makeContext()
      return RecordCounts(
        bookmarks: count(SessionBookmark.self, in: context),
        notes: count(UserNote.self, in: context),
        searches: count(RecentSearch.self, in: context),
        filterPreferences: count(ProjectFilterPreference.self, in: context),
        notifications: count(NotificationHistoryRecord.self, in: context),
        auditEvents: count(AuditEventRecord.self, in: context)
      )
    }
  }

  public func clearAllUserData() throws {
    try withPersistenceSignpost("user_data.clear_all") {
      let context = makeContext()
      try deleteAllRecords(SessionBookmark.self, in: context)
      try deleteAllRecords(UserNote.self, in: context)
      try deleteAllRecords(RecentSearch.self, in: context)
      try deleteAllRecords(ProjectFilterPreference.self, in: context)
      try deleteAllRecords(NotificationHistoryRecord.self, in: context)
      try deleteAllRecords(AuditEventRecord.self, in: context)
      try saveChanges(context)
    }
  }

  public func waitForIdle() {}

  private func makeContext() -> ModelContext {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    return context
  }

  private func evictOldSearches(in context: ModelContext) throws {
    var descriptor = FetchDescriptor<RecentSearch>(
      sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
    )
    descriptor.fetchOffset = maxRecentSearches

    let stale = try context.fetch(descriptor)
    guard !stale.isEmpty else {
      return
    }

    for search in stale {
      context.delete(search)
    }
    try saveChanges(context)
  }

  private func taskUserNoteDescriptor(
    taskID: String,
    sessionID: String
  ) -> FetchDescriptor<UserNote> {
    let targetKind = "task"
    let targetID = taskID
    let selectedSessionID = sessionID
    return FetchDescriptor<UserNote>(
      predicate: #Predicate<UserNote> { note in
        note.targetKind == targetKind
          && note.targetId == targetID
          && note.sessionId == selectedSessionID
      }
    )
  }

  private func deleteAllRecords<T: PersistentModel>(
    _ type: T.Type,
    in context: ModelContext
  ) throws {
    let items = try context.fetch(FetchDescriptor<T>())
    for item in items {
      context.delete(item)
    }
  }

  private func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) -> Int {
    (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
  }

  private func withPersistenceSignpost<Result>(
    _ name: StaticString,
    _ operation: () throws -> Result
  ) rethrows -> Result {
    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(name, id: signpostID)
    defer {
      Self.signposter.endInterval(name, interval)
    }
    return try operation()
  }
}
