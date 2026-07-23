import Foundation

public struct IssueCommentPayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let updatedAt: String?
  public let actor: ReviewTimelineActor?
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
    actor: ReviewTimelineActor? = nil,
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

public enum ReviewReviewState: String, Codable, Equatable, Sendable {
  case pending
  case commented
  case approved
  case changesRequested = "changes_requested"
  case dismissed
}

public struct ReviewPayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let actor: ReviewTimelineActor?
  public let state: ReviewReviewState
  public let body: String?
  public let url: String?
  public let inlineComments: [ReviewInlineCommentPayload]
  public let commentsTruncated: Bool

  public init(
    id: String,
    createdAt: String,
    actor: ReviewTimelineActor? = nil,
    state: ReviewReviewState,
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
  public let line: Int32?
  public let originalLine: Int32?
  public let diffHunk: String?
  public let body: String
  public let createdAt: String
  public let actor: ReviewTimelineActor?
  public let replyToId: String?
  public let outdated: Bool
  public let url: String?

  public init(
    id: String,
    path: String,
    position: Int32? = nil,
    line: Int32? = nil,
    originalLine: Int32? = nil,
    diffHunk: String? = nil,
    body: String,
    createdAt: String,
    actor: ReviewTimelineActor? = nil,
    replyToId: String? = nil,
    outdated: Bool = false,
    url: String? = nil
  ) {
    self.id = id
    self.path = path
    self.position = position
    self.line = line
    self.originalLine = originalLine
    self.diffHunk = diffHunk
    self.body = body
    self.createdAt = createdAt
    self.actor = actor
    self.replyToId = replyToId
    self.outdated = outdated
    self.url = url
  }
}

public struct ReviewThreadPayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let actor: ReviewTimelineActor?
  public let isResolved: Bool
  public let isCollapsed: Bool
  public let path: String
  public let line: Int32?
  public let originalLine: Int32?
  public let diffSide: String?
  public let diffHunk: String?
  public let outdated: Bool
  public let comments: [ReviewThreadCommentPayload]
  public let commentsTruncated: Bool

  public init(
    id: String,
    createdAt: String,
    actor: ReviewTimelineActor? = nil,
    isResolved: Bool = false,
    isCollapsed: Bool = false,
    path: String,
    line: Int32? = nil,
    originalLine: Int32? = nil,
    diffSide: String? = nil,
    diffHunk: String? = nil,
    outdated: Bool = false,
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
    self.diffHunk = diffHunk
    self.outdated = outdated
    self.comments = comments
    self.commentsTruncated = commentsTruncated
  }

  /// Returns a copy of this thread with `isResolved` set to the given
  /// value, preserving every other field. Used by the per-PR view
  /// model when the store toggles `isResolved` optimistically — see
  /// `ReviewTimelineViewModel.updateReviewThreadResolved`.
  public func updatingResolved(to resolved: Bool) -> Self {
    Self(
      id: id,
      createdAt: createdAt,
      actor: actor,
      isResolved: resolved,
      isCollapsed: isCollapsed,
      path: path,
      line: line,
      originalLine: originalLine,
      diffSide: diffSide,
      diffHunk: diffHunk,
      outdated: outdated,
      comments: comments,
      commentsTruncated: commentsTruncated
    )
  }
}

public struct ReviewThreadCommentPayload: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let body: String
  public let createdAt: String
  public let actor: ReviewTimelineActor?
  public let url: String?

  public init(
    id: String,
    body: String,
    createdAt: String,
    actor: ReviewTimelineActor? = nil,
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
  public let actor: ReviewTimelineActor?
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
    actor: ReviewTimelineActor? = nil,
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
  public let actor: ReviewTimelineActor?
  public let beforeOid: String
  public let beforeAbbreviatedOid: String
  public let afterOid: String
  public let afterAbbreviatedOid: String
  public let refName: String?

  public init(
    id: String,
    createdAt: String,
    actor: ReviewTimelineActor? = nil,
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
  public let actor: ReviewTimelineActor?
  public let typename: String
  public let rawPayload: AnyCodableJSONValue?

  public init(
    id: String,
    createdAt: String,
    actor: ReviewTimelineActor? = nil,
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
  case unsignedInteger(UInt64)
  case string(String)
  case array([Self])
  case object([String: Self])

  public init(from decoder: Decoder) throws {
    let single = try decoder.singleValueContainer()
    if single.decodeNil() {
      self = .null
    } else if let value = try? single.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? single.decode(UInt64.self),
      value > 9_007_199_254_740_992
    {
      self = .unsignedInteger(value)
    } else if let value = try? single.decode(Double.self) {
      self = .number(value)
    } else if let value = try? single.decode(String.self) {
      self = .string(value)
    } else if let value = try? single.decode([Self].self) {
      self = .array(value)
    } else if let value = try? single.decode([String: Self].self) {
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
    case .unsignedInteger(let value): try single.encode(value)
    case .string(let value): try single.encode(value)
    case .array(let value): try single.encode(value)
    case .object(let value): try single.encode(value)
    }
  }
}
