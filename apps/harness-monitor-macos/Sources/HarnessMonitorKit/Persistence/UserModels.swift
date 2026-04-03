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
