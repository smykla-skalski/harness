import Foundation

/// Request body for the `/v1/reviews/review-threads/resolve`
/// HTTP route (and matching WS method). Mirrors the Rust
/// `ReviewsReviewThreadResolveRequest`:
/// `{ thread_id, resolved, pull_request_id }`. The `pullRequestId`
/// rides along so the daemon can drain that PR's timeline cache
/// after the GraphQL mutation succeeds.
public struct ReviewsReviewThreadResolveRequest: Codable, Equatable, Sendable {
  public let threadId: String
  public let resolved: Bool
  public let pullRequestId: String

  public init(threadId: String, resolved: Bool, pullRequestId: String) {
    self.threadId = threadId
    self.resolved = resolved
    self.pullRequestId = pullRequestId
  }
}

/// Echo of the server-side `isResolved` flag returned by the
/// `resolveReviewThread` / `unresolveReviewThread` GraphQL mutation.
/// The store reconciles the optimistic toggle against this value.
public struct ReviewsReviewThreadResolveResponse: Codable, Equatable, Sendable {
  public let threadId: String
  public let resolved: Bool

  public init(threadId: String, resolved: Bool) {
    self.threadId = threadId
    self.resolved = resolved
  }
}
