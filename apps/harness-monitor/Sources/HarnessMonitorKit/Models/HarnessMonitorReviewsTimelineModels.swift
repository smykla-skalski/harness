import Foundation

public struct ReviewTimelineActor: Codable, Equatable, Sendable {
  public let login: String
  public let avatarURL: URL?

  public init(login: String, avatarURL: URL? = nil) {
    self.login = login
    self.avatarURL = avatarURL
  }

  enum CodingKeys: String, CodingKey {
    case login
    case avatarURL = "avatarUrl"
  }
}

public enum ReviewTimelineKind: String, Codable, Equatable, Sendable, CaseIterable {
  case issueComment
  case review
  case reviewThread
  case commit
  case headRefForcePushed
  case headRefDeleted
  case headRefRestored
  case baseRefChanged
  case baseRefForcePushed
  case baseRefDeleted
  case labeled
  case unlabeled
  case assigned
  case unassigned
  case merged
  case closed
  case reopened
  case renamedTitle
  case reviewRequested
  case reviewRequestRemoved
  case reviewDismissed
  case readyForReview
  case convertToDraft
  case autoMergeEnabled
  case autoMergeDisabled
  case autoRebaseEnabled
  case autoSquashEnabled
  case locked
  case unlocked
  case pinned
  case unpinned
  case milestoned
  case demilestoned
  case referenced
  case crossReferenced
  case mentioned
  case subscribed
  case unsubscribed
  case markedAsDuplicate
  case unmarkedAsDuplicate
  case transferred
  case connected
  case disconnected
  case revisionMarker
  case unknown
}

public enum ReviewTimelinePageDirection: String, Codable, Equatable, Sendable {
  case older
  case newer
}

public struct ReviewTimelinePageInfo: Codable, Equatable, Sendable {
  public let startCursor: String?
  public let endCursor: String?
  public let hasOlder: Bool
  public let hasNewer: Bool

  public init(
    startCursor: String? = nil,
    endCursor: String? = nil,
    hasOlder: Bool = false,
    hasNewer: Bool = false
  ) {
    self.startCursor = startCursor
    self.endCursor = endCursor
    self.hasOlder = hasOlder
    self.hasNewer = hasNewer
  }
}

public struct ReviewsTimelineRequest: Codable, Equatable, Sendable {
  public let pullRequestId: String
  public let cursor: String?
  public let pageSize: UInt32
  public let direction: ReviewTimelinePageDirection
  public let forceRefresh: Bool
  public let pullRequestUpdatedAt: String?

  public init(
    pullRequestId: String,
    cursor: String? = nil,
    pageSize: UInt32 = 50,
    direction: ReviewTimelinePageDirection = .older,
    forceRefresh: Bool = false,
    pullRequestUpdatedAt: String? = nil
  ) {
    self.pullRequestId = pullRequestId
    self.cursor = cursor
    self.pageSize = pageSize
    self.direction = direction
    self.forceRefresh = forceRefresh
    self.pullRequestUpdatedAt = pullRequestUpdatedAt
  }
}

public struct ReviewsTimelineResponse: Codable, Equatable, Sendable {
  public let pullRequestId: String
  public let entries: [ReviewTimelineEntry]
  public let pageInfo: ReviewTimelinePageInfo
  public let viewerCanComment: Bool
  public let fetchedAt: String

  public init(
    pullRequestId: String,
    entries: [ReviewTimelineEntry],
    pageInfo: ReviewTimelinePageInfo,
    viewerCanComment: Bool,
    fetchedAt: String
  ) {
    self.pullRequestId = pullRequestId
    self.entries = entries
    self.pageInfo = pageInfo
    self.viewerCanComment = viewerCanComment
    self.fetchedAt = fetchedAt
  }
}

public enum ReviewTimelineEntry: Equatable, Sendable, Identifiable {
  case issueComment(IssueCommentPayload)
  case review(ReviewPayload)
  case reviewThread(ReviewThreadPayload)
  case commit(CommitPayload)
  case headRefForcePushed(HeadRefForcePushedPayload)
  case simpleActorEvent(SimpleActorEventPayload)
  case unknown(UnknownTimelinePayload)

  public var id: String {
    switch self {
    case .issueComment(let payload): return payload.id
    case .review(let payload): return payload.id
    case .reviewThread(let payload): return payload.id
    case .commit(let payload): return payload.id
    case .headRefForcePushed(let payload): return payload.id
    case .simpleActorEvent(let payload): return payload.id
    case .unknown(let payload): return payload.id
    }
  }

  public var recordedAt: String {
    switch self {
    case .issueComment(let payload): return payload.createdAt
    case .review(let payload): return payload.createdAt
    case .reviewThread(let payload): return payload.createdAt
    case .commit(let payload): return payload.createdAt
    case .headRefForcePushed(let payload): return payload.createdAt
    case .simpleActorEvent(let payload): return payload.createdAt
    case .unknown(let payload): return payload.createdAt
    }
  }

  public var actor: ReviewTimelineActor? {
    switch self {
    case .issueComment(let payload): return payload.actor
    case .review(let payload): return payload.actor
    case .reviewThread(let payload): return payload.actor
    case .commit(let payload): return payload.actor
    case .headRefForcePushed(let payload): return payload.actor
    case .simpleActorEvent(let payload): return payload.actor
    case .unknown(let payload): return payload.actor
    }
  }

  public var kind: ReviewTimelineKind {
    switch self {
    case .issueComment: return .issueComment
    case .review: return .review
    case .reviewThread: return .reviewThread
    case .commit: return .commit
    case .headRefForcePushed: return .headRefForcePushed
    case .simpleActorEvent(let payload): return payload.eventKind.timelineKind
    case .unknown: return .unknown
    }
  }
}

extension ReviewTimelineEntry: Codable {
  private enum WireKind: String, Codable {
    case issueComment = "issue_comment"
    case review
    case reviewThread = "review_thread"
    case commit
    case headRefForcePushed = "head_ref_force_pushed"
    case simpleActorEvent = "simple_actor_event"
    case unknown
  }

  private enum CodingKeys: String, CodingKey {
    case kind
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(WireKind.self, forKey: .kind)
    switch kind {
    case .issueComment:
      self = .issueComment(try IssueCommentPayload(from: decoder))
    case .review:
      self = .review(try ReviewPayload(from: decoder))
    case .reviewThread:
      self = .reviewThread(try ReviewThreadPayload(from: decoder))
    case .commit:
      self = .commit(try CommitPayload(from: decoder))
    case .headRefForcePushed:
      self = .headRefForcePushed(try HeadRefForcePushedPayload(from: decoder))
    case .simpleActorEvent:
      self = .simpleActorEvent(try SimpleActorEventPayload(from: decoder))
    case .unknown:
      self = .unknown(try UnknownTimelinePayload(from: decoder))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var tagContainer = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .issueComment(let payload):
      try tagContainer.encode(WireKind.issueComment, forKey: .kind)
      try payload.encode(to: encoder)
    case .review(let payload):
      try tagContainer.encode(WireKind.review, forKey: .kind)
      try payload.encode(to: encoder)
    case .reviewThread(let payload):
      try tagContainer.encode(WireKind.reviewThread, forKey: .kind)
      try payload.encode(to: encoder)
    case .commit(let payload):
      try tagContainer.encode(WireKind.commit, forKey: .kind)
      try payload.encode(to: encoder)
    case .headRefForcePushed(let payload):
      try tagContainer.encode(WireKind.headRefForcePushed, forKey: .kind)
      try payload.encode(to: encoder)
    case .simpleActorEvent(let payload):
      try tagContainer.encode(WireKind.simpleActorEvent, forKey: .kind)
      try payload.encode(to: encoder)
    case .unknown(let payload):
      try tagContainer.encode(WireKind.unknown, forKey: .kind)
      try payload.encode(to: encoder)
    }
  }
}
