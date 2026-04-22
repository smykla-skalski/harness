import Foundation

extension BookmarkStore {
  public struct Record: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
      case projectRoot = "project-root"
      case sessionDirectory = "session-directory"
    }

    public let id: String
    public var kind: Kind
    public var displayName: String
    public var lastResolvedPath: String
    public var bookmarkData: Data
    public var handoffBookmarkData: Data?
    public var createdAt: Date
    public var lastAccessedAt: Date
    public var staleCount: Int

    public init(
      id: String = "B-" + UUID().uuidString.lowercased(),
      kind: Kind,
      displayName: String,
      lastResolvedPath: String,
      bookmarkData: Data,
      handoffBookmarkData: Data? = nil,
      createdAt: Date = .now,
      lastAccessedAt: Date = .now,
      staleCount: Int = 0
    ) {
      self.id = id
      self.kind = kind
      self.displayName = displayName
      self.lastResolvedPath = lastResolvedPath
      self.bookmarkData = bookmarkData
      self.handoffBookmarkData = handoffBookmarkData
      self.createdAt = createdAt
      self.lastAccessedAt = lastAccessedAt
      self.staleCount = staleCount
    }
  }

  public struct PersistedStore: Codable, Sendable {
    public static let currentSchemaVersion: Int = 1
    public var schemaVersion: Int
    public var bookmarks: [Record]

    public init(schemaVersion: Int = Self.currentSchemaVersion, bookmarks: [Record] = []) {
      self.schemaVersion = schemaVersion
      self.bookmarks = bookmarks
    }
  }
}
