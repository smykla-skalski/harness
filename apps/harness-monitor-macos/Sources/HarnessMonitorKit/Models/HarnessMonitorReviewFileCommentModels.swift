import Foundation

public enum ReviewsFileCommentKind: String, Codable, Equatable, Sendable {
  case newThread = "new_thread"
  case reply
}

public struct ReviewsFileCommentRequest: Codable, Equatable, Sendable {
  public let pullRequestId: String
  public let repository: String?
  public let kind: ReviewsFileCommentKind
  public let body: String
  public let path: String?
  public let line: UInt32?
  public let side: String?
  public let threadId: String?

  public init(
    pullRequestId: String,
    repository: String? = nil,
    kind: ReviewsFileCommentKind,
    body: String,
    path: String? = nil,
    line: UInt32? = nil,
    side: String? = nil,
    threadId: String? = nil
  ) {
    self.pullRequestId = pullRequestId
    self.repository = repository
    self.kind = kind
    self.body = body
    self.path = path
    self.line = line
    self.side = side
    self.threadId = threadId
  }
}

public struct ReviewsFileCommentResponse: Codable, Equatable, Sendable {
  public let pullRequestId: String
  public let threadId: String?
  public let commentId: String?
  public let url: String?
  public let fetchedAt: String

  public init(
    pullRequestId: String,
    threadId: String? = nil,
    commentId: String? = nil,
    url: String? = nil,
    fetchedAt: String
  ) {
    self.pullRequestId = pullRequestId
    self.threadId = threadId
    self.commentId = commentId
    self.url = url
    self.fetchedAt = fetchedAt
  }
}
