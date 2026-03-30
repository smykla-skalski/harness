import Foundation
import SwiftData

extension HarnessStore {
  private static let maxRecentSearches = 20

  // MARK: - Bookmarks

  public func toggleBookmark(sessionId: String, projectId: String) {
    guard let modelContext else { return }

    var descriptor = FetchDescriptor<SessionBookmark>(
      predicate: #Predicate { $0.sessionId == sessionId }
    )
    descriptor.fetchLimit = 1

    if let existing = try? modelContext.fetch(descriptor).first {
      modelContext.delete(existing)
    } else {
      modelContext.insert(SessionBookmark(sessionId: sessionId, projectId: projectId))
    }

    try? modelContext.save()
    refreshBookmarkedSessionIds()
  }

  public func isBookmarked(sessionId: String) -> Bool {
    bookmarkedSessionIds.contains(sessionId)
  }

  public func refreshBookmarkedSessionIds() {
    guard let modelContext else {
      bookmarkedSessionIds = []
      return
    }

    let descriptor = FetchDescriptor<SessionBookmark>()
    let bookmarks = (try? modelContext.fetch(descriptor)) ?? []
    bookmarkedSessionIds = Set(bookmarks.map(\.sessionId))
  }

  // MARK: - User notes

  public func addNote(
    text: String,
    targetKind: String,
    targetId: String,
    sessionId: String
  ) {
    guard let modelContext else { return }

    let note = UserNote(
      targetKind: targetKind,
      targetId: targetId,
      sessionId: sessionId,
      text: text
    )
    modelContext.insert(note)
    try? modelContext.save()
  }

  public func notes(for targetId: String) -> [UserNote] {
    guard let modelContext else { return [] }

    let descriptor = FetchDescriptor<UserNote>(
      predicate: #Predicate { $0.targetId == targetId },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )

    return (try? modelContext.fetch(descriptor)) ?? []
  }

  public func deleteNote(_ note: UserNote) {
    guard let modelContext else { return }

    modelContext.delete(note)
    try? modelContext.save()
  }

  // MARK: - Recent searches

  public func recordSearch(_ query: String) {
    guard let modelContext else { return }

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    var descriptor = FetchDescriptor<RecentSearch>(
      predicate: #Predicate { $0.query == trimmed }
    )
    descriptor.fetchLimit = 1

    if let existing = try? modelContext.fetch(descriptor).first {
      existing.lastUsedAt = .now
      existing.useCount += 1
    } else {
      modelContext.insert(RecentSearch(query: trimmed))
    }

    try? modelContext.save()
    evictOldSearches(in: modelContext)
  }

  public var recentSearches: [RecentSearch] {
    guard let modelContext else { return [] }

    var descriptor = FetchDescriptor<RecentSearch>(
      sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
    )
    descriptor.fetchLimit = Self.maxRecentSearches

    return (try? modelContext.fetch(descriptor)) ?? []
  }

  public func clearSearchHistory() {
    guard let modelContext else { return }

    let descriptor = FetchDescriptor<RecentSearch>()
    guard let searches = try? modelContext.fetch(descriptor) else { return }

    for search in searches {
      modelContext.delete(search)
    }
    try? modelContext.save()
  }

  // MARK: - Filter preferences

  public func saveFilterPreference(for projectId: String) {
    guard let modelContext else { return }

    var descriptor = FetchDescriptor<ProjectFilterPreference>(
      predicate: #Predicate { $0.projectId == projectId }
    )
    descriptor.fetchLimit = 1

    if let existing = try? modelContext.fetch(descriptor).first {
      existing.sessionFilterRaw = sessionFilter.rawValue
      existing.sessionFocusFilterRaw = sessionFocusFilter.rawValue
    } else {
      let preference = ProjectFilterPreference(
        projectId: projectId,
        sessionFilterRaw: sessionFilter.rawValue,
        sessionFocusFilterRaw: sessionFocusFilter.rawValue
      )
      modelContext.insert(preference)
    }

    try? modelContext.save()
  }

  public func loadFilterPreference(for projectId: String) {
    guard let modelContext else { return }

    var descriptor = FetchDescriptor<ProjectFilterPreference>(
      predicate: #Predicate { $0.projectId == projectId }
    )
    descriptor.fetchLimit = 1

    guard let preference = try? modelContext.fetch(descriptor).first else {
      return
    }

    if let filter = SessionFilter(rawValue: preference.sessionFilterRaw) {
      sessionFilter = filter
    }
    if let focus = SessionFocusFilter(rawValue: preference.sessionFocusFilterRaw) {
      sessionFocusFilter = focus
    }
  }

  private func evictOldSearches(in context: ModelContext) {
    var descriptor = FetchDescriptor<RecentSearch>(
      sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
    )
    descriptor.fetchOffset = Self.maxRecentSearches

    guard let stale = try? context.fetch(descriptor), !stale.isEmpty else {
      return
    }

    for search in stale {
      context.delete(search)
    }
    try? context.save()
  }
}
