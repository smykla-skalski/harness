import Foundation
import HarnessMonitorKit

@MainActor
struct SidebarSessionContextMenuScope: Equatable {
  struct SessionItem: Equatable {
    let sessionID: String
    let projectID: String
    let title: String
    let isBookmarked: Bool

    init(session: SessionSummary, isBookmarked: Bool) {
      self.sessionID = session.sessionId
      self.projectID = session.projectId
      self.title = session.title
      self.isBookmarked = isBookmarked
    }
  }

  let sessions: [SessionItem]

  static func resolve(
    rowSession: SessionSummary,
    selectedSessionIDs: Set<String>,
    orderedVisibleSessions: [SessionSummary],
    bookmarkedSessionIDs: Set<String>
  ) -> Self {
    let scopedIDs: Set<String> =
      if selectedSessionIDs.contains(rowSession.sessionId) {
        selectedSessionIDs
      } else {
        [rowSession.sessionId]
      }
    let orderedSessions = orderedVisibleSessions.filter { scopedIDs.contains($0.sessionId) }
    let resolvedSessions = orderedSessions.isEmpty ? [rowSession] : orderedSessions

    return Self(
      sessions: resolvedSessions.map { session in
        SessionItem(
          session: session,
          isBookmarked: bookmarkedSessionIDs.contains(session.sessionId)
        )
      }
    )
  }

  var usesMultiSelection: Bool {
    sessions.count > 1
  }

  var bookmarkTargets: [SessionItem] {
    shouldRemoveBookmarks
      ? sessions.filter(\.isBookmarked)
      : sessions.filter { !$0.isBookmarked }
  }

  var shouldRemoveBookmarks: Bool {
    sessions.allSatisfy(\.isBookmarked)
  }

  var bookmarkLabel: String {
    if shouldRemoveBookmarks {
      return usesMultiSelection ? "Remove Bookmarks" : "Remove Bookmark"
    }
    return usesMultiSelection ? "Bookmark Sessions" : "Bookmark"
  }

  var bookmarkSystemImage: String {
    shouldRemoveBookmarks ? "bookmark.slash" : "bookmark"
  }

  var copyTitleLabel: String {
    usesMultiSelection ? "Copy Titles" : "Copy Title"
  }

  var copyTitleText: String {
    sessions.map(\.title).joined(separator: "\n")
  }

  var canCopyTitles: Bool {
    sessions.contains { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  var copySessionIDLabel: String {
    usesMultiSelection ? "Copy Session IDs" : "Copy Session ID"
  }

  var copySessionIDText: String {
    sessions.map(\.sessionID).joined(separator: "\n")
  }

  var removeLabel: String {
    usesMultiSelection ? "Remove Sessions..." : "Remove Session..."
  }

  var sessionIDs: [String] {
    sessions.map(\.sessionID)
  }
}
