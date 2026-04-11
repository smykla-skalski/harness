import Foundation
import SwiftData

extension HarnessMonitorStore {
  private static let maxRecentSearches = 20

  public var bookmarkedSessionIds: Set<String> {
    get { userData.bookmarkedSessionIds }
    set { userData.bookmarkedSessionIds = newValue }
  }

  public var isPersistenceAvailable: Bool {
    modelContext != nil && persistenceError == nil
  }

  // MARK: - Bookmarks

  @discardableResult
  public func toggleBookmark(sessionId: String, projectId: String) -> Bool {
    guard
      let modelContext = unavailablePersistenceContext(
        for: "Bookmark changes could not be saved."
      )
    else {
      return false
    }

    do {
      var descriptor = FetchDescriptor<SessionBookmark>(
        predicate: #Predicate { $0.sessionId == sessionId }
      )
      descriptor.fetchLimit = 1
      let isAddingBookmark: Bool

      if let existing = try modelContext.fetch(descriptor).first {
        modelContext.delete(existing)
        isAddingBookmark = false
      } else {
        modelContext.insert(SessionBookmark(sessionId: sessionId, projectId: projectId))
        isAddingBookmark = true
      }

      try modelContext.save()
      updateBookmarkedSessionIds(sessionId: sessionId, isBookmarked: isAddingBookmark)
      return true
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Bookmark changes could not be saved.",
        underlyingError: error
      )
      return false
    }
  }

  public func isBookmarked(sessionId: String) -> Bool {
    bookmarkedSessionIds.contains(sessionId)
  }

  public func refreshBookmarkedSessionIds() {
    guard let modelContext, persistenceError == nil else {
      bookmarkedSessionIds = []
      return
    }

    do {
      let bookmarks = try modelContext.fetch(FetchDescriptor<SessionBookmark>())
      bookmarkedSessionIds = Set(bookmarks.map(\.sessionId))
    } catch {
      bookmarkedSessionIds = []
      recordPersistenceFailure(
        action: "Bookmarks could not be loaded.",
        underlyingError: error
      )
    }
  }

  private func updateBookmarkedSessionIds(sessionId: String, isBookmarked: Bool) {
    if isBookmarked {
      bookmarkedSessionIds.insert(sessionId)
    } else {
      bookmarkedSessionIds.remove(sessionId)
    }
  }

  // MARK: - User notes

  @discardableResult
  public func addNote(
    text: String,
    targetKind: String,
    targetId: String,
    sessionId: String
  ) -> Bool {
    guard
      let modelContext = unavailablePersistenceContext(
        for: "Note changes could not be saved."
      )
    else {
      return false
    }

    let note = UserNote(
      targetKind: targetKind,
      targetId: targetId,
      sessionId: sessionId,
      text: text
    )

    do {
      modelContext.insert(note)
      try modelContext.save()
      return true
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Note changes could not be saved.",
        underlyingError: error
      )
      return false
    }
  }

  @discardableResult
  public func deleteNote(_ note: UserNote) -> Bool {
    guard
      let modelContext = unavailablePersistenceContext(
        for: "Note changes could not be saved."
      )
    else {
      return false
    }

    do {
      modelContext.delete(note)
      try modelContext.save()
      return true
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Note changes could not be saved.",
        underlyingError: error
      )
      return false
    }
  }

  // MARK: - Recent searches

  @discardableResult
  public func recordSearch(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    guard
      let modelContext = unavailablePersistenceContext(
        for: "Search history could not be updated."
      )
    else {
      return false
    }

    do {
      var descriptor = FetchDescriptor<RecentSearch>(
        predicate: #Predicate { $0.query == trimmed }
      )
      descriptor.fetchLimit = 1

      if let existing = try modelContext.fetch(descriptor).first {
        existing.lastUsedAt = .now
        existing.useCount += 1
      } else {
        modelContext.insert(RecentSearch(query: trimmed))
      }

      try modelContext.save()
      try evictOldSearches(in: modelContext)
      return true
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Search history could not be updated.",
        underlyingError: error
      )
      return false
    }
  }

  @discardableResult
  public func clearSearchHistory() -> Bool {
    guard
      let modelContext = unavailablePersistenceContext(
        for: "Search history could not be cleared."
      )
    else {
      return false
    }

    do {
      let searches = try modelContext.fetch(FetchDescriptor<RecentSearch>())
      for search in searches {
        modelContext.delete(search)
      }
      try modelContext.save()
      return true
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Search history could not be cleared.",
        underlyingError: error
      )
      return false
    }
  }

  // MARK: - Filter preferences

  public func saveFilterPreference(for projectId: String) {
    guard let modelContext, persistenceError == nil else { return }

    do {
      var descriptor = FetchDescriptor<ProjectFilterPreference>(
        predicate: #Predicate { $0.projectId == projectId }
      )
      descriptor.fetchLimit = 1

      if let existing = try modelContext.fetch(descriptor).first {
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

      try modelContext.save()
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Filter preferences could not be saved.",
        underlyingError: error
      )
    }
  }

  public func loadFilterPreference(for projectId: String) {
    guard let modelContext, persistenceError == nil else { return }

    do {
      var descriptor = FetchDescriptor<ProjectFilterPreference>(
        predicate: #Predicate { $0.projectId == projectId }
      )
      descriptor.fetchLimit = 1

      guard let preference = try modelContext.fetch(descriptor).first else {
        return
      }

      if let filter = SessionFilter(rawValue: preference.sessionFilterRaw) {
        sessionFilter = filter
      }
      if let focus = SessionFocusFilter(rawValue: preference.sessionFocusFilterRaw) {
        sessionFocusFilter = focus
      }
    } catch {
      recordPersistenceFailure(
        action: "Filter preferences could not be loaded.",
        underlyingError: error
      )
    }
  }

  private func evictOldSearches(in context: ModelContext) throws {
    var descriptor = FetchDescriptor<RecentSearch>(
      sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
    )
    descriptor.fetchOffset = Self.maxRecentSearches

    let stale = try context.fetch(descriptor)
    guard !stale.isEmpty else {
      return
    }

    for search in stale {
      context.delete(search)
    }
    try context.save()
  }

  func persistenceFailureMessage(
    action: String,
    underlyingError: (any Error)?
  ) -> String {
    let base = """
      Local persistence is unavailable. Harness Monitor will keep running, but bookmarks, notes, and \
      search history are disabled.
      """
    guard let underlyingError else {
      return "\(base) \(action)"
    }
    return "\(base) \(action) Underlying error: \(underlyingError.localizedDescription)"
  }

  func recordPersistenceFailure(
    action: String,
    underlyingError: any Error
  ) {
    let message = persistenceFailureMessage(
      action: action,
      underlyingError: underlyingError
    )
    persistenceError = message
    presentFailureFeedback(message)
    bookmarkedSessionIds = []
  }

  func unavailablePersistenceContext(
    for action: String
  ) -> ModelContext? {
    guard let modelContext, persistenceError == nil else {
      presentFailureFeedback(
        persistenceError
          ?? persistenceFailureMessage(
            action: action,
            underlyingError: nil
          )
      )
      return nil
    }
    return modelContext
  }
}
