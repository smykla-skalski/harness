import SwiftData

extension UserDataPersistenceService {
  public struct RecordCounts: Sendable {
    public let bookmarks: Int
    public let notes: Int
    public let searches: Int
    public let filterPreferences: Int
    public let notifications: Int
    public let auditEvents: Int

    public static let zero = Self(
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

  public struct AuditEventCachePage: Equatable, Sendable {
    public let events: [HarnessMonitorAuditEvent]
    public let hasOlder: Bool
  }

  public struct UserNoteIdentity: @unchecked Sendable {
    let persistentID: PersistentIdentifier

    public init(_ note: UserNote) {
      self.persistentID = note.persistentModelID
    }
  }
}
