import Foundation
import SwiftData
import os

public actor UserDataPersistenceService {
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
    try loadAuditEventPage(limit: limit).events
  }

  public func loadAuditEventPage(limit: Int = 500) throws -> AuditEventCachePage {
    try withPersistenceSignpost("user_data.audit_events.fetch") {
      let context = makeContext()
      let resolvedLimit = max(limit, 1)
      var descriptor = FetchDescriptor<AuditEventRecord>(
        sortBy: [
          SortDescriptor(\.recordedAt, order: .reverse),
          SortDescriptor(\.eventID, order: .forward),
        ]
      )
      descriptor.fetchLimit = resolvedLimit + 1
      var records = try context.fetch(descriptor)
      let hasOlder = records.count > resolvedLimit
      if hasOlder {
        records.removeLast()
      }
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
      return AuditEventCachePage(
        events: events.sorted(by: HarnessMonitorAuditEvent.auditEventSort),
        hasOlder: hasOlder
      )
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

}
