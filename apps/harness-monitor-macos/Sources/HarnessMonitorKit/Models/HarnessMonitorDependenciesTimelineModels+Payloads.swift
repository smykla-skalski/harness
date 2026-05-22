import Foundation

public struct IssueCommentPayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let updatedAt: String?
  public let actor: DependencyUpdateTimelineActor?
  public let body: String
  public let bodyText: String?
  public let isMinimized: Bool
  public let minimizedReason: String?
  public let reactionsTotal: UInt32
  public let viewerDidAuthor: Bool
  public let viewerCanEdit: Bool
  public let url: String?

  public init(
    id: String,
    createdAt: String,
    updatedAt: String? = nil,
    actor: DependencyUpdateTimelineActor? = nil,
    body: String,
    bodyText: String? = nil,
    isMinimized: Bool = false,
    minimizedReason: String? = nil,
    reactionsTotal: UInt32 = 0,
    viewerDidAuthor: Bool = false,
    viewerCanEdit: Bool = false,
    url: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.actor = actor
    self.body = body
    self.bodyText = bodyText
    self.isMinimized = isMinimized
    self.minimizedReason = minimizedReason
    self.reactionsTotal = reactionsTotal
    self.viewerDidAuthor = viewerDidAuthor
    self.viewerCanEdit = viewerCanEdit
    self.url = url
  }
}

public enum DependencyUpdateReviewState: String, Codable, Equatable, Sendable {
  case pending
  case commented
  case approved
  case changesRequested = "changes_requested"
  case dismissed
}

public struct ReviewPayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let actor: DependencyUpdateTimelineActor?
  public let state: DependencyUpdateReviewState
  public let body: String?
  public let url: String?
  public let inlineComments: [ReviewInlineCommentPayload]
  public let commentsTruncated: Bool

  public init(
    id: String,
    createdAt: String,
    actor: DependencyUpdateTimelineActor? = nil,
    state: DependencyUpdateReviewState,
    body: String? = nil,
    url: String? = nil,
    inlineComments: [ReviewInlineCommentPayload] = [],
    commentsTruncated: Bool = false
  ) {
    self.id = id
    self.createdAt = createdAt
    self.actor = actor
    self.state = state
    self.body = body
    self.url = url
    self.inlineComments = inlineComments
    self.commentsTruncated = commentsTruncated
  }
}

public struct ReviewInlineCommentPayload: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let path: String
  public let position: Int32?
  public let body: String
  public let createdAt: String
  public let actor: DependencyUpdateTimelineActor?
  public let replyToId: String?
  public let url: String?

  public init(
    id: String,
    path: String,
    position: Int32? = nil,
    body: String,
    createdAt: String,
    actor: DependencyUpdateTimelineActor? = nil,
    replyToId: String? = nil,
    url: String? = nil
  ) {
    self.id = id
    self.path = path
    self.position = position
    self.body = body
    self.createdAt = createdAt
    self.actor = actor
    self.replyToId = replyToId
    self.url = url
  }
}

public struct ReviewThreadPayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let actor: DependencyUpdateTimelineActor?
  public let isResolved: Bool
  public let isCollapsed: Bool
  public let path: String
  public let line: Int32?
  public let originalLine: Int32?
  public let diffSide: String?
  public let comments: [ReviewThreadCommentPayload]
  public let commentsTruncated: Bool

  public init(
    id: String,
    createdAt: String,
    actor: DependencyUpdateTimelineActor? = nil,
    isResolved: Bool = false,
    isCollapsed: Bool = false,
    path: String,
    line: Int32? = nil,
    originalLine: Int32? = nil,
    diffSide: String? = nil,
    comments: [ReviewThreadCommentPayload] = [],
    commentsTruncated: Bool = false
  ) {
    self.id = id
    self.createdAt = createdAt
    self.actor = actor
    self.isResolved = isResolved
    self.isCollapsed = isCollapsed
    self.path = path
    self.line = line
    self.originalLine = originalLine
    self.diffSide = diffSide
    self.comments = comments
    self.commentsTruncated = commentsTruncated
  }
}

public struct ReviewThreadCommentPayload: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let body: String
  public let createdAt: String
  public let actor: DependencyUpdateTimelineActor?
  public let url: String?

  public init(
    id: String,
    body: String,
    createdAt: String,
    actor: DependencyUpdateTimelineActor? = nil,
    url: String? = nil
  ) {
    self.id = id
    self.body = body
    self.createdAt = createdAt
    self.actor = actor
    self.url = url
  }
}

public struct CommitPayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let actor: DependencyUpdateTimelineActor?
  public let oid: String
  public let abbreviatedOid: String
  public let messageHeadline: String
  public let committedDate: String?
  public let authorName: String?
  public let authorLogin: String?
  public let url: String?

  public init(
    id: String,
    createdAt: String,
    actor: DependencyUpdateTimelineActor? = nil,
    oid: String,
    abbreviatedOid: String,
    messageHeadline: String,
    committedDate: String? = nil,
    authorName: String? = nil,
    authorLogin: String? = nil,
    url: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.actor = actor
    self.oid = oid
    self.abbreviatedOid = abbreviatedOid
    self.messageHeadline = messageHeadline
    self.committedDate = committedDate
    self.authorName = authorName
    self.authorLogin = authorLogin
    self.url = url
  }
}

public struct HeadRefForcePushedPayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let actor: DependencyUpdateTimelineActor?
  public let beforeOid: String
  public let beforeAbbreviatedOid: String
  public let afterOid: String
  public let afterAbbreviatedOid: String
  public let refName: String?

  public init(
    id: String,
    createdAt: String,
    actor: DependencyUpdateTimelineActor? = nil,
    beforeOid: String,
    beforeAbbreviatedOid: String,
    afterOid: String,
    afterAbbreviatedOid: String,
    refName: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.actor = actor
    self.beforeOid = beforeOid
    self.beforeAbbreviatedOid = beforeAbbreviatedOid
    self.afterOid = afterOid
    self.afterAbbreviatedOid = afterAbbreviatedOid
    self.refName = refName
  }
}

public struct UnknownTimelinePayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let actor: DependencyUpdateTimelineActor?
  public let typename: String
  public let rawPayload: AnyCodableJSONValue?

  public init(
    id: String,
    createdAt: String,
    actor: DependencyUpdateTimelineActor? = nil,
    typename: String,
    rawPayload: AnyCodableJSONValue? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.actor = actor
    self.typename = typename
    self.rawPayload = rawPayload
  }
}

/// Type-erased JSON value carried inside `UnknownTimelinePayload.rawPayload`
/// so the Swift side can hand off forward-compat event data to whichever
/// renderer ultimately learns how to display it.
public enum AnyCodableJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([AnyCodableJSONValue])
  case object([String: AnyCodableJSONValue])

  public init(from decoder: Decoder) throws {
    let single = try decoder.singleValueContainer()
    if single.decodeNil() {
      self = .null
    } else if let value = try? single.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? single.decode(Double.self) {
      self = .number(value)
    } else if let value = try? single.decode(String.self) {
      self = .string(value)
    } else if let value = try? single.decode([AnyCodableJSONValue].self) {
      self = .array(value)
    } else if let value = try? single.decode([String: AnyCodableJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: single,
        debugDescription: "unsupported JSON value"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var single = encoder.singleValueContainer()
    switch self {
    case .null: try single.encodeNil()
    case .bool(let value): try single.encode(value)
    case .number(let value): try single.encode(value)
    case .string(let value): try single.encode(value)
    case .array(let value): try single.encode(value)
    case .object(let value): try single.encode(value)
    }
  }
}
