import Foundation
import SwiftData

extension HarnessMonitorStore {
  static let maxRecentSearches = 20

  public var bookmarkedSessionIds: Set<String> {
    get { userData.bookmarkedSessionIds }
    set { userData.bookmarkedSessionIds = newValue }
  }

  public var isPersistenceAvailable: Bool {
    userDataService != nil && persistenceError == nil
  }

  // MARK: - Bookmarks

  @discardableResult
  public func toggleBookmark(sessionId: String, projectId: String) async -> Bool {
    guard
      let userDataService = unavailablePersistenceService(
        for: "Bookmark changes could not be saved."
      )
    else {
      return false
    }

    do {
      let isAddingBookmark = try await userDataService.toggleBookmark(
        sessionId: sessionId,
        projectId: projectId
      )
      updateBookmarkedSessionIds(sessionId: sessionId, isBookmarked: isAddingBookmark)
      return true
    } catch {
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

  public func refreshBookmarkedSessionIds() async {
    guard let userDataService, persistenceError == nil else {
      bookmarkedSessionIds = []
      return
    }

    do {
      bookmarkedSessionIds = try await userDataService.bookmarkIDs()
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
  ) async -> Bool {
    guard
      let userDataService = unavailablePersistenceService(
        for: "Note changes could not be saved."
      )
    else {
      return false
    }

    do {
      try await userDataService.addNote(
        text: text,
        targetKind: targetKind,
        targetId: targetId,
        sessionId: sessionId
      )
      return true
    } catch {
      recordPersistenceFailure(
        action: "Note changes could not be saved.",
        underlyingError: error
      )
      return false
    }
  }

  @discardableResult
  public func deleteNote(_ note: UserNote) async -> Bool {
    guard
      let userDataService = unavailablePersistenceService(
        for: "Note changes could not be saved."
      )
    else {
      return false
    }

    do {
      return try await userDataService.deleteNote(.init(note))
    } catch {
      recordPersistenceFailure(
        action: "Note changes could not be saved.",
        underlyingError: error
      )
      return false
    }
  }

  // MARK: - Recent searches

  @discardableResult
  public func recordSearch(_ query: String) async -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    guard
      let userDataService = unavailablePersistenceService(
        for: "Search history could not be updated."
      )
    else {
      return false
    }

    do {
      return try await userDataService.recordSearch(trimmed)
    } catch {
      recordPersistenceFailure(
        action: "Search history could not be updated.",
        underlyingError: error
      )
      return false
    }
  }

  @discardableResult
  public func clearSearchHistory() async -> Bool {
    guard
      let userDataService = unavailablePersistenceService(
        for: "Search history could not be cleared."
      )
    else {
      return false
    }

    do {
      try await userDataService.clearSearchHistory()
      return true
    } catch {
      recordPersistenceFailure(
        action: "Search history could not be cleared.",
        underlyingError: error
      )
      return false
    }
  }

  // MARK: - Filter settings

  public func saveFilterPreference(for projectId: String) async {
    guard let userDataService, persistenceError == nil else { return }

    do {
      try await userDataService.saveFilterPreference(
        projectId: projectId,
        sessionFilterRaw: sessionFilter.rawValue,
        sessionFocusFilterRaw: sessionFocusFilter.rawValue
      )
    } catch {
      recordPersistenceFailure(
        action: "Filter settings could not be saved.",
        underlyingError: error
      )
    }
  }

  public func loadFilterPreference(for projectId: String) async {
    guard let userDataService, persistenceError == nil else { return }

    do {
      guard let preference = try await userDataService.loadFilterPreference(projectId: projectId)
      else {
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
        action: "Filter settings could not be loaded.",
        underlyingError: error
      )
    }
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

  func unavailablePersistenceService(
    for action: String
  ) -> UserDataPersistenceService? {
    guard let userDataService, persistenceError == nil else {
      presentFailureFeedback(
        persistenceError
          ?? persistenceFailureMessage(
            action: action,
            underlyingError: nil
          )
      )
      return nil
    }
    return userDataService
  }

  func scheduleBookmarkedSessionRefresh() {
    guard userDataService != nil else {
      bookmarkedSessionIds = []
      return
    }
    Task { @MainActor [weak self] in
      await self?.refreshBookmarkedSessionIds()
    }
  }
}
