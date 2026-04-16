import Foundation

public struct TimelineEntry: Codable, Equatable, Identifiable, Sendable {
  public let entryId: String
  public let recordedAt: String
  public let kind: String
  public let sessionId: String
  public let agentId: String?
  public let taskId: String?
  public let summary: String
  public let payload: JSONValue

  public var id: String { entryId }
}

public struct TimelineCursor: Codable, Equatable, Sendable {
  public let recordedAt: String
  public let entryId: String

  public init(recordedAt: String, entryId: String) {
    self.recordedAt = recordedAt
    self.entryId = entryId
  }
}

public struct TimelineWindowRequest: Codable, Equatable, Sendable {
  public let scope: TimelineScope?
  public let limit: Int?
  public let before: TimelineCursor?
  public let after: TimelineCursor?
  public let knownRevision: Int64?

  public init(
    scope: TimelineScope? = nil,
    limit: Int? = nil,
    before: TimelineCursor? = nil,
    after: TimelineCursor? = nil,
    knownRevision: Int64? = nil
  ) {
    self.scope = scope
    self.limit = limit
    self.before = before
    self.after = after
    self.knownRevision = knownRevision
  }

  public static func latest(
    limit: Int,
    scope: TimelineScope = .summary,
    knownRevision: Int64? = nil
  ) -> Self {
    Self(
      scope: scope,
      limit: limit,
      knownRevision: knownRevision
    )
  }
}

public struct TimelineWindowResponse: Codable, Equatable, Sendable {
  public let revision: Int64
  public let totalCount: Int
  public let windowStart: Int
  public let windowEnd: Int
  public let hasOlder: Bool
  public let hasNewer: Bool
  public let oldestCursor: TimelineCursor?
  public let newestCursor: TimelineCursor?
  public let entries: [TimelineEntry]?
  public let unchanged: Bool

  public init(
    revision: Int64,
    totalCount: Int,
    windowStart: Int,
    windowEnd: Int,
    hasOlder: Bool,
    hasNewer: Bool,
    oldestCursor: TimelineCursor?,
    newestCursor: TimelineCursor?,
    entries: [TimelineEntry]?,
    unchanged: Bool
  ) {
    self.revision = revision
    self.totalCount = totalCount
    self.windowStart = windowStart
    self.windowEnd = windowEnd
    self.hasOlder = hasOlder
    self.hasNewer = hasNewer
    self.oldestCursor = oldestCursor
    self.newestCursor = newestCursor
    self.entries = entries
    self.unchanged = unchanged
  }

  public var pageSize: Int {
    max(1, windowEnd - windowStart)
  }

  public var metadataOnly: Self {
    Self(
      revision: revision,
      totalCount: totalCount,
      windowStart: windowStart,
      windowEnd: windowEnd,
      hasOlder: hasOlder,
      hasNewer: hasNewer,
      oldestCursor: oldestCursor,
      newestCursor: newestCursor,
      entries: nil,
      unchanged: unchanged
    )
  }

  public func replacingEntries(_ entries: [TimelineEntry]?) -> Self {
    Self(
      revision: revision,
      totalCount: totalCount,
      windowStart: windowStart,
      windowEnd: windowEnd,
      hasOlder: hasOlder,
      hasNewer: hasNewer,
      oldestCursor: oldestCursor,
      newestCursor: newestCursor,
      entries: entries,
      unchanged: unchanged
    )
  }

  public static func fallbackMetadata(for entries: [TimelineEntry]) -> Self {
    Self(
      revision: 0,
      totalCount: entries.count,
      windowStart: 0,
      windowEnd: entries.count,
      hasOlder: false,
      hasNewer: false,
      oldestCursor: entries.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      newestCursor: entries.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      entries: nil,
      unchanged: false
    )
  }
}

public struct LogLevelResponse: Codable, Equatable, Sendable {
  public let level: String
  public let filter: String

  public init(level: String, filter: String) {
    self.level = level
    self.filter = filter
  }
}

public struct SetLogLevelRequest: Codable, Equatable, Sendable {
  public let level: String

  public init(level: String) {
    self.level = level
  }
}

public struct SessionsUpdatedPayload: Codable, Equatable, Sendable {
  public let projects: [ProjectSummary]
  public let sessions: [SessionSummary]
}

public struct SessionUpdatedPayload: Codable, Equatable, Sendable {
  public let detail: SessionDetail
  public let timeline: [TimelineEntry]?
  public let extensionsPending: Bool?
}

public struct StreamEvent: Codable, Equatable, Identifiable, Sendable {
  public let event: String
  public let recordedAt: String
  public let sessionId: String?
  public let payload: JSONValue
  private let stableID = UUID()

  public var id: UUID { stableID }
  enum CodingKeys: String, CodingKey { case event, recordedAt, sessionId, payload }

  public init(event: String, recordedAt: String, sessionId: String?, payload: JSONValue) {
    self.event = event
    self.recordedAt = recordedAt
    self.sessionId = sessionId
    self.payload = payload
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.event == rhs.event && lhs.recordedAt == rhs.recordedAt
      && lhs.sessionId == rhs.sessionId && lhs.payload == rhs.payload
  }
}

extension StreamEvent {
  private static let payloadEncoder = JSONEncoder()
  private static let payloadDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  public func decodePayload<Payload: Decodable>(as type: Payload.Type) throws -> Payload {
    let data = try Self.payloadEncoder.encode(payload)
    return try Self.payloadDecoder.decode(type, from: data)
  }
}
